import Foundation
import MultipeerConnectivity

/// Anything that can carry events. The backend fans every new event out to all transports and
/// ingests whatever they bring back; the store dedupes.
protocol EventTransport: AnyObject {
    func publish(_ event: SignedEvent)
    func start()
    func stop()
}

/// Phone-to-phone over Wi-Fi/Bluetooth with MultipeerConnectivity. No internet, no server:
/// everyone at the venue syncs directly. Peers exchange the ids they hold and fill each other's gaps.
final class MeshTransport: NSObject, EventTransport, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, @unchecked Sendable {
    private let serviceType = "mmt-mesh"
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let store: EventStore
    private(set) var peers: Int = 0
    var onPeersChanged: (@Sendable (Int) -> Void)?

    init(store: EventStore, displayName: String) {
        self.store = store
        peerID = MCPeerID(displayName: String(displayName.prefix(60)))
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        super.init()
        session.delegate = self; advertiser.delegate = self; browser.delegate = self
    }

    func start() { advertiser.startAdvertisingPeer(); browser.startBrowsingForPeers() }
    func stop() { advertiser.stopAdvertisingPeer(); browser.stopBrowsingForPeers(); session.disconnect() }

    enum Frame: Codable { case have([String]), want([String]), events([SignedEvent]) }

    func publish(_ event: SignedEvent) { send(.events([event]), to: session.connectedPeers) }

    private func send(_ frame: Frame, to peers: [MCPeerID]) {
        guard !peers.isEmpty, let data = try? JSONEncoder.event.encode(frame) else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    // MARK: MCSessionDelegate
    func session(_ session: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        peers = session.connectedPeers.count; onPeersChanged?(peers)
        if state == .connected { Task { let ids = await store.ids(); send(.have(Array(ids)), to: [peer]) } }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        guard let frame = try? JSONDecoder.event.decode(Frame.self, from: data) else { return }
        Task {
            switch frame {
            case .have(let theirs):
                let mine = await store.ids()
                let missing = mine.subtracting(theirs)
                if !missing.isEmpty { let evs = await store.get(Array(missing)); for chunk in stride(from: 0, to: evs.count, by: 20) { send(.events(Array(evs[chunk..<min(chunk + 20, evs.count)])), to: [peer]) } }
                let want = Set(theirs).subtracting(mine)
                if !want.isEmpty { send(.want(Array(want)), to: [peer]) }
            case .want(let ids):
                let evs = await store.get(ids)
                for chunk in stride(from: 0, to: evs.count, by: 20) { send(.events(Array(evs[chunk..<min(chunk + 20, evs.count)])), to: [peer]) }
            case .events(let evs):
                for e in evs { await store.ingest(e) }
            }
        }
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    // MARK: Discovery — everyone running MOMENT nearby is a peer; the encryption is per-Moment, not per-link.
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) { invitationHandler(true, session) }
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) { browser.invitePeer(peerID, to: session, withContext: nil, timeout: 20) }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}

/// Relays: dumb, open WebSocket servers anyone can run (see `relay/`). Protocol is four JSON frames:
/// ["EVENT", event] · ["REQ", id, filter] · ["EOSE", id] · ["CLOSE", id]. Relays verify signatures and
/// keep events; they never see inside non-public Moments. Users choose their relays.
final class RelayTransport: NSObject, EventTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    struct Filter: Codable { var kinds: [String]? = nil; var authors: [String]? = nil; var moments: [String]? = nil; var geo: [String]? = nil; var since: Int? = nil; var tags: [String: String]? = nil }

    private let store: EventStore
    private var urls: [URL]
    private var tasks: [URL: URLSessionWebSocketTask] = [:]
    private var pending: [URL: [String]] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private(set) var connected: Set<URL> = []
    var onConnectionChanged: (@Sendable (Int) -> Void)?
    private var subscriptions: [String: Filter] = [:]

    init(store: EventStore, relays: [URL]) { self.store = store; self.urls = relays; super.init() }

    func start() { for u in urls { connect(u) } }
    func stop() { for (_, t) in tasks { t.cancel(with: .goingAway, reason: nil) }; tasks = [:]; connected = [] }
    func setRelays(_ new: [URL]) { stop(); urls = new; start() }

    private func connect(_ url: URL) {
        let t = session.webSocketTask(with: url)
        tasks[url] = t
        t.resume()
        receive(on: t, url: url)
    }

    func publish(_ event: SignedEvent) {
        guard let data = try? JSONEncoder.event.encode(event), let json = String(data: data, encoding: .utf8) else { return }
        let frame = "[\"EVENT\",\(json)]"
        for (u, t) in tasks { if connected.contains(u) { t.send(.string(frame)) { _ in } } else { pending[u, default: []].append(frame) } }
    }

    /// Ask relays for what this device cares about: my follows, my Moments, public activity in cells.
    func subscribe(id: String, _ filter: Filter) {
        subscriptions[id] = filter
        guard let data = try? JSONEncoder.event.encode(filter), let json = String(data: data, encoding: .utf8) else { return }
        let frame = "[\"REQ\",\"\(id)\",\(json)]"
        for (u, t) in tasks { if connected.contains(u) { t.send(.string(frame)) { _ in } } else { pending[u, default: []].append(frame) } }
    }

    private func receive(on task: URLSessionWebSocketTask, url: URL) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                if case .string(let s) = msg, let data = s.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [Any], arr.count >= 2, (arr[0] as? String) == "EVENT",
                   let evData = try? JSONSerialization.data(withJSONObject: arr[1]), let e = try? JSONDecoder.event.decode(SignedEvent.self, from: evData) {
                    Task { await self.store.ingest(e) }
                }
                self.receive(on: task, url: url)
            case .failure:
                self.connected.remove(url); self.onConnectionChanged?(self.connected.count)
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in guard let self, self.tasks[url] != nil else { return }; self.connect(url) }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard let url = webSocketTask.originalRequest?.url else { return }
        connected.insert(url); onConnectionChanged?(connected.count)
        for f in pending[url] ?? [] { webSocketTask.send(.string(f)) { _ in } }
        pending[url] = nil
        for (id, filter) in subscriptions { if let data = try? JSONEncoder.event.encode(filter), let json = String(data: data, encoding: .utf8) { webSocketTask.send(.string("[\"REQ\",\"\(id)\",\(json)]")) { _ in } } }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if let url = webSocketTask.originalRequest?.url { connected.remove(url); onConnectionChanged?(connected.count) }
    }
}
