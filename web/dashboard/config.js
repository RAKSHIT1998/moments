// CloudKit JS configuration for the venue dashboard.
// 1. CloudKit Dashboard → your container → API Access → Tokens → "Create API Token" (with Sign in with Apple).
// 2. Paste the token below and set the environment ("development" until the schema is deployed to production).
// The dashboard reads only the PUBLIC database; owners sign in with their Apple ID (the same iCloud identity the app uses).
window.MOMENT_CK = {
  containerIdentifier: "iCloud.com.rakshitbargotra.moment",
  apiToken: "REPLACE_WITH_CLOUDKIT_API_TOKEN",
  environment: "development"
};
