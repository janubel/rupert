# Local AI on SER8: test report, 2026-10-22

**Written:** 2026-10-22 18:50 UTC. All times are UTC.

**Scope:** Rupert team chat bots. One cloud bot, @rupert (DeepSeek V4.1 Flash via OpenCode Go). Local models served by the `rupert-llm` gateway on SER8.

**Grading:** every answer is graded 1–5 by DeepSeek V4.1 Flash against what Rupert's own tools return for the same question, at the time of the run.

**Records:** every run is saved in `chat_battery_runs`, viewable on Model scores → Test runs, and each bot's answers are in its `#test-<bot>` room. This report contains grades and timings only, no business figures.

## Headline

| Rank | Model (file) | Where | Finance | General | Avg time per answer |
| --- | --- | --- | --- | --- | --- |
| 1 | **Qwen3.6-35B-A3B** (Unsloth UD-Q3_K_S, 15.4 GB) | SER8 780M | **4.62** | **4.33** | 14–18 s |
| 2 | DeepSeek V4.1 Flash (@rupert) | cloud | 4.57 | — | 7.5 s |
| 3 | Qwen3.5-4B (@qwen, Q4_K_M) | SER8 780M | 4.52 | — | 13.5 s |
| 4 | LFM2.5-24B-A2B (QAD Q4_0) | SER8 780M | 4.14 | 4.05 | 24–29 s |
| 5 | LFM2.5-8B-A1B (@liquid, Q4_K_M) | SER8 780M | 3.43 | 4.10 | 18–20 s |
| 6 | Gemma 4 E4B (@gemma, QAT Q4_0) | SER8 780M | — | 3.52* | 5.9 s |

\* Gemma 4 E4B was graded only in round 1, before the round 2–3 changes that lifted the other models.

**Takeaways**

- **A local model now matches the cloud model on money questions.** Qwen3.6-35B-A3B scored 4.62 vs DeepSeek's 4.57, privately on SER8, in about 14 s. It's a mixture-of-experts model (35B total, about 3B active), so it runs at small-model speed.
- **Most of the gains came from Rupert's side, not model size.** Between the first and latest runs:
  - Qwen3.5-4B went from 3.43 to 4.52 on finance.
  - Liquid 8B went from 3.38 to 4.10 on general questions.

  The changes behind that:
  - tools that return finished figures, with ready dollar amounts;
  - a "copy figures, never calculate" rule, backed by a number check;
  - topic-matched tools and data cards (data guide);
  - exact dates worked out before the model sees the question.
- **Moving from the CPU to the Radeon 780M cut answers from 1–2 minutes to 6–30 s.**
- **One run per model and question set.** Grades can move a few tenths between runs, so gaps under about 0.3 are not conclusive.

## Hardware (SER8)

| | |
| --- | --- |
| Machine | Beelink SER8, AMD Ryzen 7 8745HS (8 cores / 16 threads, up to 4.97 GHz, Zen 4, AVX-512 VNNI/BF16) |
| GPU | AMD Radeon 780M (HawkPoint1, RDNA3, gfx1103), cooperative-matrix (matrix cores) and fp16 support |
| GPU memory | 4.0 GiB BIOS carve-out + 13.3 GiB GTT (system RAM) = 17.3 GiB; Vulkan reports 17,739 MiB |
| System RAM | 32 GB, of which 26.6 GiB is visible to the OS |
| Storage | 915 GB NVMe; 278 GB free after these models were added |
| Host OS | Ubuntu 26.04.1 LTS, kernel 7.0.0-38-generic, Incus 6.0.5 |
| GPU power setting | `power_dpm_force_performance_level=auto` (default, not tuned) |

**Model container `rupert-llm`:** Ubuntu 24.04.5, `limits.cpu=8`, `limits.memory=14GiB`.
- **Access:** the GPU is passed in as `gpu0` (gid 990 = `llm`). Only `rupert` can reach it, and it has no internet access.
- **Memory accounting:** GPU memory is not charged to the 14 GiB limit. With a 13 GB model on the GPU, the container used about 230 MB.
- **Size ceiling:** with Qwen3.6-35B (15.4 GB) loaded, the 780M had 2.2 GB free. That is the practical size limit unless GTT is raised (kernel `amdgpu.gttsize`, plus a reboot).

| Software | Version |
| --- | --- |
| llama.cpp | official Vulkan build b11819 (commit 0693dbfb9), `/opt/llama/current`; CPU fallback `llama-prism-b10787-73bfe6c` kept |
| Vulkan driver | Mesa RADV 25.2.8 (`mesa-vulkan-drivers 25.2.8-0ubuntu0.24.04.4`), `libvulkan1 1.3.275` |
| Gateway | `llm_gateway.py`: one model at a time, unloads after 10 idle minutes, logs prompt-cache use per request |
| Settings for every model | `--n-gpu-layers 99 --flash-attn on --batch-size 2048 --ctx-size 16384` |
| `--ubatch-size` | 2048 for the LFM models, 1024 for Gemma and Qwen3.6, 512 for Qwen3.5-4B |

## Model files (in `/var/lib/rupert-llm/models`, added 2026-10-22)

| Model id | File | Bytes | SHA-256 |
| --- | --- | --- | --- |
| `qwen3.6-35b-a3b` | Qwen3.6-35B-A3B-UD-Q3_K_S.gguf (unsloth/Qwen3.6-35B-A3B-GGUF) | 15,359,196,128 | `212ccdf37d416167ce8dcd7e3a59bcd45b30ac7531822a1e7bb79bfbacb2d1aa` |
| `lfm2.5-24b-a2b` | LFM2.5-24B-A2B-QAD-Q4_0.gguf (LiquidAI/LFM2.5-24B-A2B-GGUF) | 13,578,190,880 | `d1c03f73ecaf61017d70419eec9e5dc0b05d50ae26c23d522829b934fbabf8a5` |
| `lfm2.5-8b-a1b` | LFM2.5-8B-A1B-Q4_K_M.gguf | 5,155,564,768 | `4923ec14f06b968b74d663e5949867d2d9c3bf13a20b8be1a9f9af39989b2bb0` |
| `qwen3.5-4b` | Qwen3.5-4B-Q4_K_M.gguf | 2,740,937,888 | `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4` |
| `gemma-4-e4b` | gemma-4-E4B_q4_0-it.gguf (Google QAT) | 5,154,941,280 | `676c35070db6dbe52f93e9c864ee0fba4eddea94b9c875d9cb10daff453fbaee` |
| `gemma-4-e4b-ud` | gemma-4-E4B-it-UD-Q4_K_XL.gguf | 5,126,306,944 | `3cf61de12daa015ee0f7b68e7b7c541405bf220e1e942bad8b47cab827d7df80` |
| `gemma-4-e2b` | gemma-4-E2B-it-UD-Q4_K_XL.gguf | 3,184,496,736 | `b52f438017efaec5debf1c0d8be690571e212a07c312f1102bbce927258cfc32` |

Ternary Bonsai 2 9B was removed (too slow) and its file deleted.

## Speed benchmarks (`llama-bench`, tokens per second)

**CPU vs 780M** (about 15:00, host, b11819, 4,096-token prompt):

| Model | Prompt, CPU | Prompt, 780M | Generate, CPU | Generate, 780M |
| --- | --- | --- | --- | --- |
| LFM2.5 8B-A1B Q4_K_M | 253 | 1,219 | 46 | 66 |
| Gemma 4 E4B QAT Q4_0 | 118 | 698 | 14 | 25 |
| Gemma 4 E4B UD-Q4_K_XL | 136 | 555 | 15 | 23 |
| Gemma 4 E2B UD-Q4_K_XL | 264 | 1,035 | 26 | 44 |

Through Rupert, "How were sales yesterday?" on @gemma went from 112 s (CPU) to 22 s (780M).

**Tuning sweep** (about 17:00, inside `rupert-llm`, 4,096-token prompt; generation speed did not change with any setting):

| Model | Default | Flash attention + best ubatch | Best ubatch |
| --- | --- | --- | --- |
| LFM2.5 8B-A1B | 921 | 1,212 | 2048 |
| LFM2.5 24B-A2B | 584 | 893 | 2048 |
| Gemma 4 E4B | 639 | 691 | 1024 |
| Qwen3.5 4B | 465 | 481 | 512 |

The q8_0 KV cache gave no speed gain (memory only), so it is not used. ROCm was not tried: gfx1103 crashes in recent HIP builds (llama.cpp #20839), and Vulkan is the documented path for this iGPU.

**Where the time goes:**
- **Within an answer:** the gateway logs show the second step of an answer reuses the first step's prompt from cache (about 9,000 tokens in under a second).
- **Between questions:** each new question re-read its prompt (about 8 s at 9,000 tokens) until #356, which keeps the instructions identical between questions.
- **Bigger models:** for LFM2.5-24B, writing (about 380 tokens a step at 43 t/s) is now most of the time.

## Every test run

Each run is 21 questions unless noted. The "general" set is `config/team_chat/battery.yml`; the "finance" set is `battery_finance.yml`.

| Started (UTC) | Bot | Model | Set | Answered | Grade | Avg / slowest (s) | Flagged | Rupert build | Round |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 15:38 | @liquid | lfm2.5-8b-a1b | general | 21/21 | 3.38 | 9.8 / 33.7 | — | (pre-scorecard) | 1 |
| 15:43 | @gemma | gemma-4-e4b | general | 21/21 | 3.52 | 5.9 / 22.1 | — | (pre-scorecard) | 1 |
| 15:55 | @liquid | lfm2.5-8b-a1b | finance | 19/21 | 2.95 | 10.2 / 24.1 | — | (pre-scorecard) | 1 |
| 16:00 | @qwen | qwen3.5-4b | finance | 21/21 | 3.43 | 11.2 / 30.1 | — | (pre-scorecard) | 1 |
| 16:05 | @rupert | deepseek-v4.1-flash | finance | 21/21 | 4.57 | 7.5 / 13.6 | — | (pre-scorecard) | 1 |
| 16:12 | @liquid | lfm2.5-8b-a1b | general, 9 weak questions | 9/9 | 2.67 | 27.2 / 54.2 | 0 | (pre-scorecard) | 2 |
| 16:16 | @liquid | lfm2.5-8b-a1b | finance | 20/21 | 3.19 | 20.5 / 85.5 | 5 | (pre-scorecard) | 2 |
| 16:45 | @liquid | lfm2.5-8b-a1b | finance | 20/21 | 3.43 | 18.0 / 75.4 | 3 | (pre-scorecard) | 3 |
| 16:52 | @qwen | qwen3.5-4b | finance | 21/21 | 4.52 | 13.5 / 31.8 | 1 | (pre-scorecard) | 3 |
| 16:58 | @liquid | lfm2.5-8b-a1b | general | 21/21 | 4.10 | 19.5 / 57.4 | 0 | (pre-scorecard) | 3 |
| 18:03 | lfm-24b | lfm2.5-24b-a2b | general | 20/21 | 4.05 | 28.9 / 127.9 | 1 | e3431a81e667 | 4 |
| 18:15 | lfm-24b | lfm2.5-24b-a2b | finance | 21/21 | 4.14 | 24.1 / 57.6 | 5 | 01d769d951b8 | 4 |
| 18:24 | qwen-35b | qwen3.6-35b-a3b | general | 20/21 | 4.33 | 17.8 / 35.0 | 0 | 01d769d951b8 | 4 |
| 18:31 | qwen-35b | qwen3.6-35b-a3b | finance | 21/21 | 4.62 | 14.3 / 35.3 | 1 | 01d769d951b8 | 4 |

The 9 weak questions in round 2 averaged about 1.9 in round 1. "Flagged" means answers whose figures the number check could not find in Rupert's data; "—" means the run predates the number check.

**Grades by topic, latest finance runs:**

| Model | Sales | Comparison | Money out | Tax | Books | Honesty |
| --- | --- | --- | --- | --- | --- | --- |
| Qwen3.6-35B | 4.9 | 5.0 | 5.0 | 5.0 | 4.0 | 3.0 |
| DeepSeek (@rupert) | 4.9 | 4.0 | 5.0 | 5.0 | 4.0 | 4.0 |
| Qwen3.5-4B | 4.9 | 4.3 | 5.0 | 5.0 | 3.7 | 3.5 |
| LFM2.5-24B | 4.6 | 4.7 | 5.0 | 3.0 | 4.3 | 1.0 |
| LFM2.5-8B | 3.9 | 5.0 | 3.7 | 2.0 | 3.0 | 1.0 |

**What changed between rounds:**
- **Round 1 (15:38–16:09), baseline on the 780M.** Before it, at about 15:37, the gateway moved from the CPU to the GPU.
- **Round 2 (16:12–16:24):** number check, ready dollar amounts, "copy figures, never calculate", the which-tool guide (#350).
- **Round 3 (16:45–17:06):** data guide (topic-matched tools and cards, #351), exact dates in questions, grading notes on the questions (#352).
- **Round 4 (18:03–18:43):** new models LFM2.5-24B and Qwen3.6-35B. Flash attention and per-model ubatch were live (#353). Rupert build 01d769d9 includes the Projects/Tasks, rail UI, ledger and logging merges.

## Earlier one-off trials (production, `team_chat:try`, CPU, before the GPU)

Each trial asked 4 questions: sales yesterday, low stock, sync health, make a task.

| Time | Model | Seconds per answer | Notes |
| --- | --- | --- | --- |
| about 14:30 | Gemma 4 E4B QAT Q4_0 | 91–138 | 4/4 right tool and figures |
| about 14:50 | Gemma 4 E2B UD-Q4_K_XL | 59–127 | Faster but sloppier: counted only the first page of alerts, missed the "tomorrow" due date |

## Recommendations

1. **Make Qwen3.6-35B-A3B a regular local bot**, for example @qwen replacing the 4B, or a new handle. It is the best local model on both question sets, at small-model speed. Since it fills the 780M, only one model is loaded at a time; the gateway already works that way.
2. **Keep @rupert (DeepSeek) as the cloud default and reference.** It is fastest, and equal on money questions.
3. **Keep improving Rupert's side.** Next: the metrics layer (#357, phase 1 in #361) and prompt caching between questions (#356). Then re-run these batteries and add the results here.
4. **Optional, needs the owner (root + reboot):** raise GTT (`amdgpu.gttsize`) for 4-bit versions of the 30–35B models, and set the GPU power level to `high`. Only worth it if a measured run justifies it.
5. **Re-run before deciding on any gap under 0.3:** `bin/rails team_chat:battery AGENT=… [BATTERY=finance] FORCE=1`.
