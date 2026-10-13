# Social Automation Options — Web Sales Growth

Goal context: $2,000/day web (Shopify online) sales. This covers posting to
social channels via applications/bots to drive traffic.

## Platforms & posting options

| Platform | Posting tools / apps | Bot friendliness | Notes |
|----------|---------------------|------------------|-------|
| Reddit | Official Reddit API + apps (e.g. PRAW/PRAWlib), scheduling via API | High (API, rate limits) | **No spam/self-promo.** Needs real community value. Highest risk of shadowban if purely promotional. |
| YouTube | YouTube Data API, scheduling in Studio | Low for content; high for Shorts automation | Organic content + playlists; automation is more for workflow (upload, publish) than "bots." |
| Instagram | Meta Graph API, tools like Buffer/Hootsuite/Meta Business Suite | Medium (API, throttled) | Reels drive reach; API posting is read/write but limited. |
| TikTok | Official API is limited | Low | Content app; can't meaningfully auto-post via bot. |
| X/Twitter | X API (paid tiers), Buffer/Hootsuite | High | Easy to automate; fast feedback. |
| Facebook | Meta Graph API / Business Suite | Medium | Organic reach low; boost needed. |
| Pinterest | Pinterest API | Medium | Good for product/lifestyle visuals. |
| LinkedIn | LinkedIn API (limited) | Medium | B2B, less fit for consumer herbal. |

## Recommended approach (safe + scalable)

1. **Content-first, not bot-first.** Use apps (Buffer, Hootsuite, Meta Business
   Suite) to *schedule* human-approved posts across channels from one calendar.
   Scheduling is reliable and avoids platform penalties. Bots that auto-generate
   and auto-post run high ban/shadowban risk.

2. **Use official APIs where reach matters.** Reddit (real answers in relevant
   communities — r/herbalism, r/CBD), Pinterest, and Instagram Reels are the
   strongest drivers for a herbal/wellness brand. Auto-posting bots on Reddit
   specifically are the most likely to backfire.

3. **Automate the pipeline, not the voice.** Let automation handle capture,
   scheduling, cross-posting, and analytics. Keep a human (or agent-reviewed)
   approval step before anything publishes to protect the brand.

4. **Measure against the goal.** Tag traffic as `web`/UTM source and check the
   $2k/day goal + sales_report.rb by source to see what's actually converting.

## Proposed first move

Stand up a single scheduling hub (Buffer or Hootsuite) + a Reddit presence run
by real, value-adding posts (education/how-tos, not links), and wire UTM tags so
we can measure each channel against the web-sales goal.

## Caveats

- Reddit/YouTube bot self-promotion = ban/shadowban risk. Prefer app scheduling
  over raw bots.
- Verify each tool's cost and API limits before committing.
- This is a growth/marketing plan, not a Shopify/Square data change — no impact
  on the SKU freeze or sync.
