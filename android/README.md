# MOMENT for Android

A **Trusted Web Activity**: a thin Android shell that opens `moment.social/app` full-screen, with no
address bar, as an installable app. It is the same MOMENT Web the browser runs — same Ed25519 identity,
same signed events, same relays — so there is one client to maintain rather than two.

What it deliberately is not: a native Android app. That would mean reimplementing the event protocol,
the sealed-set crypto and the whole UI a second time, and keeping the two byte-compatible forever.

## It has never been built

There is no Java runtime, Android SDK or Gradle on the machine this was written on, so **nothing here
has been compiled or run**. The project is complete and conventional, but treat the first build as a
real step, not a formality.

## Building it

```sh
brew install --cask temurin android-studio     # JDK 17 + SDK; or install the command-line tools
cd android
gradle wrapper --gradle-version 8.9            # writes gradlew, once
./gradlew assembleDebug                        # app/build/outputs/apk/debug/app-debug.apk
```

`assembleDebug` gives you an APK you can sideload today to see it work. Play needs a signed release
bundle — see below.

## Before it will be chrome-less

A TWA only drops the address bar if the site vouches for the app. Both halves must line up:

1. **Make an upload key** and keep it out of this repository:
   ```sh
   keytool -genkey -v -keystore moment-upload.jks -keyalg RSA -keysize 2048 \
           -validity 10000 -alias upload
   keytool -list -v -keystore moment-upload.jks -alias upload | grep SHA256
   ```
2. **Publish the digital asset link** at `https://moment.social/.well-known/assetlinks.json`, with that
   SHA-256 fingerprint:
   ```json
   [{
     "relation": ["delegate_permission/common.handle_all_urls"],
     "target": {
       "namespace": "android_app",
       "package_name": "social.moment.twa",
       "sha256_cert_fingerprints": ["AA:BB:…"]
     }
   }]
   ```
   If you use Play App Signing — and you should — the fingerprint Chrome needs is the **app signing
   key** Google shows you in the console, not your upload key. Getting this wrong is the usual reason a
   TWA launches with an address bar still showing.
3. Point `hostName` and `defaultUrl` in `app/build.gradle` at the domain you actually deployed.

## What Android users get, and don't

Everything MOMENT Web does: browse creators, open what they've paid for, keep their key. Posting,
selling, calls and chats are the iPhone app.

**Screenshots are not blocked here.** iOS renders paid photos inside a system layer that comes out blank
in a capture; a web view has no such layer, and a TWA is a web view. The web client says so on every
screen that shows paid media, and that warning is the honest thing to keep — not something to quietly
drop because it looks bad in a shell that feels native.
