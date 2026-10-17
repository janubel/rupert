# Rupert Staff — iPhone and Android

Native Expo/React Native client for a Rupert instance. The instance itself supplies the installable web app at `/employee`; there is no separate native-client web deployment.

## Development and validation

Use Node 24 and the committed lockfile:

```sh
npm ci
npm run check
npm run export
npx expo start
```

The login screen accepts the instance's clean HTTPS origin and the staff email/password. Optionally set `EXPO_PUBLIC_RUPERT_URL` when building for one instance. This address is public configuration, never a secret. The app rejects embedded credentials, paths, fragments, non-HTTPS addresses, and redirected API requests. Passwords are not retained. The sign-in token uses SecureStore and is removed when signing out. Server revocation, termination, and password reset invalidate access.

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

These commands require owner-controlled credentials and may incur build/account costs. Configure the intended team and store records interactively before automated submission. Complete app icons/listing/screenshots, staff sign-in test access, privacy/data declarations, support details, and organization's distribution policy before submitting. No store submission has been performed by this implementation.

After acceptance, share the approved native distribution links through the organization’s chosen staff onboarding channel. The instance’s `/employee` workspace stays focused on time, pay and leave without app promotion.

## Release acceptance

Use designated test accounts on an HTTPS staging instance. Test real iPhone and Android builds for login, revoked/expired sessions, cold starts, background/foreground, clock-in/out retries, draft creation, entries, import, submit, rejected-sheet correction, and sign-out. Reviewers use the web review workspace. Check poor connectivity: an unconfirmed mutation should be refreshed and verified before retrying. The UI never claims an offline entry was saved.

The October 16, 2026 security update fixes the transitive UUID advisory with an `xcode`-scoped override to CommonJS-compatible UUID 11.1.1. The remaining two underlying advisories have no published fixed npm version: `braces` 3.0.3 and `node-forge` 1.4.0 receive narrow, source-hashed backports during `npm ci`. Expo and React Native keep their supported versions. See [security backports](security/README.md) for provenance, regression coverage and removal instructions.

`npm run check` verifies the actual patched files and rejects any new/unexplained advisory. Raw `npm audit` still reports 15 high findings because it identifies upstream versions, including their dependent packages; the report is retained in `dist/dependency-security.json` with the two verified backports. These are not hidden findings or a claim that the registry audit is clean. Run the checks again immediately before signing, and complete real-device acceptance.

See [staff timesheets](../docs/employee-timesheets.md) for account provisioning, web installation, server deployment, and the full API contract.

## Prepared signing handoff (October 16, 2026)

The supported SDK 58 patch and lockfile now use Expo **58.0.12**. `npm run check` runs the online Expo compatibility check, TypeScript validation, staff boundaries, exploit regression tests, verified security backports and the fail-closed advisory gate. CI additionally runs Expo Doctor and exports **iOS and Android with Hermes bytecode** on x86-64 Ubuntu. Its `employee-native-js-exports-<commit>` artifact contains JavaScript/assets for verification; it is not an installable or signed app. Dependency checks remain enabled.

All EAS profiles prefill the staff app with `https://rupert.stoverparc.org`. The instance field stays editable, and this public URL contains no staff identity or credentials. For a separate staging build, change the selected profile's `EXPO_PUBLIC_RUPERT_URL` before building. The development profile uses the EAS `development` environment, preview uses `preview`, and store builds use `production`.

| Profile | iPhone / iPad | Android | Intended handoff |
| --- | --- | --- | --- |
| `development` | Simulator build | APK | Local validation; not an installable iPhone release |
| `preview` | Signed device/ad hoc build | Signed APK | Designated internal test devices |
| `production` | Signed App Store/TestFlight build | Signed AAB | Store testing and submission after acceptance |

Production explicitly uses store distribution, physical iOS devices, Android App Bundles, remote signing credentials and incrementing remote build numbers. No EAS project, organization, store app ID or signing credential has been invented. Use the owner's selected accounts when ready:

1. Choose the Expo account/organization, Apple team and Google Play organization. Confirm ownership of both `org.stoverparc.rupert.employee` identifiers, or set the documented overrides before the first signed build. Never change an identifier for an already-distributed app.
2. Run `npx eas-cli@25.0.0 login` from `mobile/`, set `EXPO_OWNER` to the selected Expo account/organization, then run `npx eas-cli@25.0.0 init`. Set the returned `EAS_PROJECT_ID` in the local/build environment; initialize only the intended organization project. The project ID and owner are public metadata. Keep passwords, signing keys, EAS/API tokens and store service-account files outside Git.
3. Run `npm ci`, `npm run check`, `npx --yes expo-doctor@1.21.4`, and `npm run export` on a supported x86-64 build machine. Check the resolved config with `npx expo config --type public`; verify owner/project, bundle identifiers, app version and intended instance before building.
4. Create the Google Play and App Store Connect records under the selected organizations. Connect signing interactively using EAS credentials. For iOS ad hoc testing, register the intended devices first. Use the matching EAS environments for any public identifier overrides; the profile's public Rupert URL is supplied explicitly.
5. Build and validate on designated staff test accounts before any submission:

   ```sh
   npx eas-cli@25.0.0 build --platform android --profile preview
   npx eas-cli@25.0.0 build --platform ios --profile preview
   npx eas-cli@25.0.0 build --platform all --profile production
   ```

6. After real-device acceptance, use `npx eas-cli@25.0.0 submit --platform ios --profile production` for TestFlight/App Store Connect and the corresponding `--platform android` command for Google Play. The first Play upload may need to be made manually in Play Console. Android submission is configured as an internal-track draft; review and release it manually in Play Console when intended. Confirm the target app interactively; submission is separate from building.
7. Complete the organization's listing, support contact, screenshots, privacy/data declarations and reviewer test access. Then share the approved HTTPS distribution links through the organization’s onboarding channel as described above.

Signing, cloud builds, credential creation, account connection and store submission are deferred. The existing web accounts, emailed setup links and held profiles do not need to change for this mobile preparation. Rerun security and compatibility validation immediately before signing; a prepared source tree does not replace signed-device acceptance.

Official references: [Expo CLI dependency checks](https://docs.expo.dev/more/expo-cli/), [EAS build profiles](https://docs.expo.dev/eas/json/), [remote version management](https://docs.expo.dev/build-reference/app-versions/), [Android submission](https://docs.expo.dev/submit/android/).
