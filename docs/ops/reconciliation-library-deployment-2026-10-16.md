# Reconciliation and document-library UX deployment — October 16, 2026

[PR #62](https://github.com/techmore/rupert/pull/62) deployed application revision `17accec72c9ea2c92e185456f99bce44c373b8cd` to SER8, preserving the complete prior release `3d927fe8fbeace6b45a1c2328a82d515293aad57`, including the POS checkout, influencer discounts and customer/staff directory changes. This pass adds no database migrations.

## Workflow improvements

**Money → Document retention library** at `/reconciliation_documents` searches originals and report versions across dates by filename, source, reference, category and covered period. Reports & statements includes retained source exports, gateway/processor reports, bank statements and fee statements; invoice searches also include retained SwipeSimple invoice exports. Native CSV date filters use export receipt dates rather than claiming transaction coverage. Metadata-only pages contain up to 24 files, with signed cursors bound to the workspace and filters.

Document cards distinguish current controls, previous versions, withdrawals, report archives and normalized snapshots. **Correct this control** opens the matching business day and source context, preserves the previous file, and requires replacement totals. Withdrawals use a selection of current controls instead of typed IDs. Invalid attachment, withdrawal and stale-review submissions preserve entered text and the selected day; an upload error explicitly asks for the file to be selected again. Reviews still bind to the current report fingerprint.

The daily page has clearer source/location names, readable timestamps, meaningful comparison status colors, Yesterday/Today shortcuts and links into the full archive library. Register controls reveal comparison fields and pin their end date to the selected start date. The file picker shows the selected size and checks supported suffixes and the 8 MiB limit; server-side byte validation remains authoritative. Wide tables support keyboard scrolling and show a phone hint. Section links leave clearance beneath the fixed phone header.

## Validation and retention

- Final combined CI at the deployed revision passed both adapters: SQLite **1,248 tests / 9,093 assertions**, zero failures/errors/skips; PostgreSQL **1,248 tests / 9,078 assertions**, zero failures/errors and two adapter-specific skips. RuboCop inspected **663 files** without offenses. Product-site, documentation and employee-mobile checks passed.
- A consistent private production-copy rehearsal passed migration/no-schema-change checks, asset builds, real-data daily/library rendering, archive byte/checksum replay, period-version retention and original decryption. Every existing table count was preserved after temporary evidence rolled back.
- Live authenticated library filters, daily workflow, desktop layout and 390px phone layout passed. The phone page had no page-wide overflow, and the upload anchor kept its heading below the fixed header. Public health returned HTTP 200; web and jobs were active on clean source.
- All **42 eligible local originals/report versions** passed checksum verification at this checkpoint. A consistent database/configuration backup passed integrity and a saved-key restore of both vault and native originals, library queries and report generation. Its off-machine encrypted archive passed decryption and every archive-member checksum and was saved in the owner-verified private backup destination.

**Google Drive remains pending at the owner's request.** No retention refresh token, cloud retention folder or verified upload was established. This pass did not attempt consent or change Drive credentials. Originals remain encrypted and available in Rupert. The earlier consent blocker and private activation note remain applicable; see the [Drive checkpoint](drive-retention-deployment-2026-10-16.md).

## Asset publication detail

Live verification caught accumulated older Sprockets manifest JSONs alongside the staged release manifest. Rails could select an older manifest even though the new fingerprinted assets were present. The older manifests were preserved in the private rollback checkpoint, leaving exactly the verified release manifest active, then web/jobs restarted. Live HTML referenced the new stylesheet, and the computed phone anchor margin was 192px.

For future staged promotions, publish exactly one verified release manifest under the configured assets prefix before restarting. Preserve superseded manifest JSONs in the rollback checkpoint and retain older fingerprinted CSS/JS files for in-flight pages. Copying an asset directory over the live directory alone is insufficient when it leaves competing manifests.

See the [daily workflow guide](daily-reconciliation-retention.md). Private source files, financial amounts, account identifiers, credentials and recovery keys remain outside public Git.
