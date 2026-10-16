# Rupert Employee — iPhone and Android

Native Expo/React Native client for a Rupert instance. The instance itself supplies the installable web app at `/employee`; there is no separate native-client web deployment.

## Development and validation

Use Node 24 and the committed lockfile:

```sh
npm ci
npx expo install --check
npm run typecheck
npm test
npm run export
npx expo start
```

The login screen accepts the instance's clean HTTPS origin and the employee email/password. Optionally set `EXPO_PUBLIC_RUPERT_URL` when building for one instance. This address is public configuration, never a secret. The app rejects embedded credentials, paths, fragments, non-HTTPS addresses, and redirected API requests. Passwords are not retained. The sign-in token uses SecureStore and is removed when signing out. Server revocation, termination, and password reset invalidate access.

On ARM Linux, Expo's supplied Hermes compiler is an x86-64 binary. Validate JavaScript bundling locally with `npx expo export --platform ios --no-bytecode` and `npx expo export --platform android --no-bytecode`. The GitHub workflow runs the normal Hermes export on x86-64 Ubuntu. Distributable binaries must use normal EAS/native compilation; the diagnostic JS exports are not IPA/APK files.

## Signing and distribution

The owner must choose the Apple Developer team, Google Play organization, and Expo/EAS project. The package/bundle default is `org.stoverparc.rupert.employee`; verify ownership or set `RUPERT_IOS_BUNDLE_ID` and `RUPERT_ANDROID_PACKAGE` before the first release. Once published, keep those IDs stable. Set `EAS_PROJECT_ID` for an existing project or initialize the project with `npx eas-cli init`. The repository contains no signing credentials or EAS account token.

```sh
npx eas-cli login
npx eas-cli init
npx eas-cli build --platform android --profile preview
npx eas-cli build --platform ios --profile preview
```

- Android preview generates an APK suitable for direct/internal distribution. Production generates the store build for Google Play.
- iOS preview uses internal/ad hoc distribution and requires a paid Apple Developer team plus registered devices. Register devices using `npx eas-cli device:create` before the build. For wider testing, build production and submit through TestFlight.
- The development profile uses an iOS simulator build and Android APK; it is not a production iPhone distribution profile.

For stores:

```sh
npx eas-cli build --platform all --profile production
npx eas-cli submit --platform ios --profile production
npx eas-cli submit --platform android --profile production
```

These commands require owner-controlled credentials and may incur build/account costs. Configure the intended team and store records interactively before automated submission. Complete app icons/listing/screenshots, employee sign-in test access, privacy/data declarations, support details, and organization's distribution policy before submitting. No store submission has been performed by this implementation.

After acceptance, configure `EMPLOYEE_IOS_DOWNLOAD_URL` / `EMPLOYEE_ANDROID_DOWNLOAD_URL` on Rupert to display the correct download links at `/employee`.

## Release acceptance

Use designated test accounts on an HTTPS staging instance. Test real iPhone and Android builds for login, revoked/expired sessions, cold starts, background/foreground, clock-in/out retries, draft creation, entries, import, submit, rejected-sheet correction, and sign-out. Reviewers use the web review workspace. Check poor connectivity: an unconfirmed mutation should be refreshed and verified before retrying. The UI never claims an offline entry was saved.

Dependency audit on October 15, 2026 found advisories in the current Expo build-tool graph (including `braces`, `node-forge`, and the older `uuid` used by `xcode`). Registry-reported current releases still include affected versions, and npm's suggested automatic fix downgrades Expo/React Native to incompatible old major releases. No forced downgrade or unverified dependency override is applied. Re-run `npm audit` and evaluate supported patched SDK/tooling before signed distribution; do not expose Metro development servers publicly. This source/build preparation does not constitute security clearance for release.

See [employee timesheets](../docs/employee-timesheets.md) for account provisioning, web installation, server deployment, and the full API contract.
