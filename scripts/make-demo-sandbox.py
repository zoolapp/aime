#!/usr/bin/env python3
"""Builds a synthetic AIME workspace for website screenshots (no real user data).

    python3 scripts/make-demo-sandbox.py <dir>

Creates <dir>/rime (AIME_USER_DIR) with a few per-app options and features enabled, and
<dir>/stats (AIME_STATS_DIR) with a year of invented typing statistics. Then deploy with
the CLI (AIME_USER_DIR=<dir>/rime aime deploy) and capture with scripts/ui-shots.sh
(AIME_UI_SOURCE=<dir>/rime AIME_UI_STATS_SOURCE=<dir>/stats).
"""
import datetime
import json
import os
import random
import sys

out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "build/demo-sandbox")
rime = os.path.join(out, "rime")
stats = os.path.join(out, "stats")
random.seed(20261001)

# Apps likely to be installed on a Mac, so icons and names resolve.
APPS = {
    "com.tencent.xinWeChat": ("chinese", 0.30),
    "com.apple.Notes": ("chinese", 0.16),
    "com.apple.Safari": ("shared", 0.12),
    "com.microsoft.VSCode": ("english", 0.10),
    "com.todesktop.230313mzl4w4u92": ("english", 0.10),  # Cursor
    "com.anthropic.claudefordesktop": ("chinese", 0.12),
    "com.apple.Terminal": ("english", 0.04),
    "com.apple.mail": ("chinese", 0.06),
}
WORDS = {
    "智能体": 64, "输入法": 58, "提示词": 41, "工作流": 37, "开源": 33, "周报": 29, "需求": 27, "设计稿": 24,
    "会议纪要": 21, "上线": 20, "复盘": 18, "用户体验": 17, "春熙路": 15, "晚饭": 14, "茶餐厅": 12,
    "部署": 12, "主题": 11, "快捷键": 10, "常用语": 9, "大模型": 9,
}

os.makedirs(os.path.join(rime, "aime", "generated"), exist_ok=True)
modes = {"chinese": "false", "english": "true"}
lines = ["patch:"]
for bundle, (mode, _) in APPS.items():
    if mode in modes:
        lines.append(f"  app_options/{bundle}:")
        lines.append(f"    ascii_mode: {modes[mode]}")
lines += ["  style/color_scheme: aime_light", "  style/color_scheme_dark: aime_dark"]
open(os.path.join(rime, "aime", "generated", "aime.yaml"), "w").write("\n".join(lines) + "\n")
json.dump({"usageStats": True, "aiPolish": True}, open(os.path.join(rime, "aime", "features.json"), "w"))
snippets = [("手机号", ["+852 6100 6100", "+86 139 1234 5678", "+1 (415) 555-0100"]),
            ("邮箱", ["hello@zool.app", "luolei@work.example", "me@personal.example"]),
            ("地址", ["香港中环皇后大道中 99 号", "成都市锦江区春熙路 1 号"]),
            ("常用回复", ["收到，谢谢！", "我晚点回复你", "好的，八点见。"])]
json.dump({"categories": [{"id": f"00000000-0000-0000-0000-00000000000{i}", "name": n, "items": items}
                          for i, (n, items) in enumerate(snippets, 1)]},
          open(os.path.join(rime, "aime", "snippets.json"), "w"), ensure_ascii=False, indent=2)

os.makedirs(os.path.join(stats, "Activity"), exist_ok=True)
today = datetime.date.today()
for offset in range(365):
    day = today - datetime.timedelta(days=offset)
    weekday = day.weekday() < 5
    if random.random() < 0.12: continue  # some days off
    total = int(random.gauss(2600 if weekday else 1300, 380))
    hours = [0] * 24
    for _ in range(total):
        hour = int(random.choice([9, 10, 11, 14, 15, 16, 17, 20, 21, 22, 23]) + random.random())
        hours[min(hour, 23)] += 1
    han = int(total * 0.84)
    apps = {b: int(total * share * random.uniform(0.8, 1.2)) for b, (_, share) in APPS.items()}
    json.dump({"han": han, "words": total - han, "commits": total // 3, "hours": hours, "apps": apps},
              open(os.path.join(stats, "Activity", f"{day.isoformat()}.json"), "w"))
    counts = {w: max(1, int(c / 30 * random.uniform(0.5, 1.6))) for w, c in WORDS.items()}
    json.dump(counts, open(os.path.join(stats, f"{day.isoformat()}.json"), "w"), ensure_ascii=False)
print("demo workspace:", out)
