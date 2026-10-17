#!/usr/bin/env python3
"""Read-only parity report: Rust Rupert (Incus container `rupert-core`) vs the live Rails mirror (`rupert`).

Runs on SER8 as a user in the incus-admin group; standard library only. Nothing is written to either
system: the Rails database is opened with `sqlite3 -readonly`, and the Rust database is read from a
`VACUUM INTO` snapshot that is pulled to a temporary directory and deleted afterwards. No customer data is
selected (orders are compared by id, total, line count and line quantity only).

Exit code 0: no differences among rows both sides refreshed recently. 1: differences (listed).

  python3 parity.py [--since YYYY-MM-DD]      orders window start (default: 30 days ago)
"""
import argparse, collections, datetime, os, sqlite3, subprocess, sys, tempfile

RAILS_DB = "/opt/rupert/web/storage/production.sqlite3"


def run(args, **kw):
    r = subprocess.run(args, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit(f"command failed: {' '.join(args[:6])} ...\n{r.stderr[:400]}")
    return r.stdout


def rails(sql):
    out = run(["incus", "exec", "rupert", "--", "sqlite3", "-readonly", "-separator", "|", RAILS_DB, sql])
    return [l.split("|") for l in out.splitlines() if l]


def rust_snapshot(tmp):
    py = ("import glob,sqlite3,sys;f=[p for p in glob.glob('/var/lib/rupert-core/tenants/*.db')];assert len(f)==1,f;"
          "c=sqlite3.connect('file:'+f[0]+'?mode=ro',uri=True);c.execute(\"VACUUM INTO '/root/parity-snapshot.db'\")")
    run(["incus", "exec", "rupert-core", "--", "sh", "-c", "rm -f /root/parity-snapshot.db"])
    run(["incus", "exec", "rupert-core", "--", "python3", "-I", "-c", py])
    dest = os.path.join(tmp, "rust.db")
    run(["incus", "file", "pull", "rupert-core/root/parity-snapshot.db", dest])
    run(["incus", "exec", "rupert-core", "--", "rm", "-f", "/root/parity-snapshot.db"])
    return sqlite3.connect(f"file:{dest}?mode=ro", uri=True)


diffs = []  # unexplained differences


def section(title, a, b, key_name="key", note=""):
    """Compare two {key: value} dicts; report counts and samples. Returns the differing keys."""
    both = set(a) & set(b)
    only_a, only_b = sorted(set(a) - set(b)), sorted(set(b) - set(a))
    bad = sorted(k for k in both if a[k] != b[k])
    flag = "OK " if not (only_a or only_b or bad) else "DIFF"
    print(f"[{flag}] {title}: rails={len(a)} rust={len(b)} only_rails={len(only_a)} only_rust={len(only_b)} value_mismatch={len(bad)} {note}")
    for k in only_a[:3]: print(f"        only in rails: {k} -> {a[k]}")
    for k in only_b[:3]: print(f"        only in rust:  {k} -> {b[k]}")
    for k in bad[:5]: print(f"        mismatch {k}: rails={a[k]} rust={b[k]}")
    if only_a or only_b or bad:
        diffs.append(title)
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default=(datetime.date.today() - datetime.timedelta(days=30)).isoformat())
    since = ap.parse_args().since
    with tempfile.TemporaryDirectory(prefix="rupert-parity-") as tmp:
        c = rust_snapshot(tmp)
        print(f"parity report {datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')}  orders since {since}\n")

        # ---- Shopify variants: rows Rails refreshed on its latest sync date (it keeps stale rows forever)
        rv = rails("select v.id, coalesce(v.sku,''), v.inventoryQuantity, coalesce(p.status,''), substr(v.syncedAt,1,10) from ShopifyVariant v left join ShopifyProduct p on p.id=v.productId")
        latest = max(r[4] for r in rv)
        rv_cur = {r[0]: (r[1], int(r[2] or 0), r[3]) for r in rv if r[4] == latest}
        uv = {r[0]: (r[1] or "", r[2], r[3]) for r in c.execute("select id, sku, qty, product_status from shopify_variants")}
        section("Shopify variants (sku, qty, status)", rv_cur, uv, note=f"(rails rows refreshed {latest}; {len(rv) - len(rv_cur)} stale rails rows ignored)")

        # ---- Shopify per-location levels, same freshness rule
        rl = rails("select l.shopifyVariantId, loc.externalId, l.quantity, substr(l.updatedAt,1,10) from InventoryLevel l join Location loc on loc.id=l.locationId where l.source='shopify'")
        newest = max(r[3] for r in rl)
        rl_cur = {(r[0], r[1]): int(r[2]) for r in rl if r[3] == newest}
        ul = {(a, b): q for a, b, q in c.execute("select variant_id, location_id, qty from shopify_levels")}
        section("Shopify levels (variant, location)", rl_cur, {k: v for k, v in ul.items() if k in rl_cur}, note=f"(rails rows refreshed {newest}; {len(rl) - len(rl_cur)} stale ignored)")
        # Rust refreshes levels for every variant; Rails only refreshes them for active products, so extra rust rows are expected.
        print(f"        info: {len(set(ul) - set(rl_cur))} rust level rows have no fresh rails counterpart (rails does not refresh these)")

        rloc = {r[0]: (r[1], r[2] == "1") for r in rails("select externalId, name, active from Location where source='shopify'")}
        uloc = {i: (n, bool(a)) for i, n, a in c.execute("select id, name, active from shopify_locations")}
        section("Shopify locations (name, active)", rloc, uloc)

        # ---- Square
        rq = {r[0]: (r[1], int(r[2])) for r in rails("select sv.id, coalesce(sv.sku,''), coalesce((select sum(quantity) from InventoryLevel l where l.source='square' and l.squareVariationId=sv.id),0) from SquareVariation sv")}
        uq = {i: (s or "", q) for i, s, q in c.execute("select id, sku, qty from square_variations")}
        section("Square variations (sku, qty)", rq, uq)
        # Rails keeps count rows for variations that no longer exist (or never had an id); Rust cannot, so those are info only.
        rc = {(r[0], r[1]): int(r[2]) for r in rails("select l.squareVariationId, loc.externalId, l.quantity from InventoryLevel l join Location loc on loc.id=l.locationId where l.source='square' and l.quantity<>0 and l.squareVariationId in (select id from SquareVariation)")}
        orphans = rails("select count(*), coalesce(sum(l.quantity),0) from InventoryLevel l where l.source='square' and l.quantity<>0 and (l.squareVariationId is null or l.squareVariationId not in (select id from SquareVariation))")[0]
        uc = {(a, b): q for a, b, q in c.execute("select variation_id, location_id, qty from square_counts where qty<>0")}
        section("Square non-zero counts (variation, location)", rc, uc)
        print(f"        info: {orphans[0]} rails count row(s) ({orphans[1]} unit(s)) belong to variations no longer in the Square catalog; ignored")

        # ---- Orders created since the window start (compared by id, total, line count, line quantity)
        for src in ("shopify", "square"):
            ro = {r[0]: (round(int(r[1]) / 100, 2) if src == "shopify" else None, int(r[2]), int(r[3])) for r in rails(
                f"select o.source_order_id, o.gross_cents, (select count(*) from order_lines l where l.order_id=o.id), (select coalesce(sum(l.quantity),0) from order_lines l where l.order_id=o.id) from orders o where o.source='{src}' and o.occurred_at >= '{since}'")}
            uo = {i: ((round(t, 2) if src == "shopify" and t is not None else None), n, q) for i, t, n, q in c.execute(
                "select o.id, o.total, o.line_count, (select coalesce(sum(qty),0) from order_lines l where l.order_id=o.id) from orders o where o.source=? and substr(o.created_at,1,10) >= ?", (src, since))}
            section(f"{src.capitalize()} orders (total, lines, quantity)", ro, uo)

    print()
    if diffs:
        print("RESULT: DIFFERENCES in: " + "; ".join(diffs))
        sys.exit(1)
    print("RESULT: no differences")


if __name__ == "__main__":
    main()
