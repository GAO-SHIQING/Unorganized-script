#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import re
from pathlib import Path
from typing import List, Tuple


WINDOWS_FORBIDDEN_CHARS = r'[<>:"/\\|?*]'
SOURCE_MD = Path(r"/home/qc/GAOSHIQING/ComfyUI/config/总类/全行业门头分类终版.md")   # 类目 Markdown 文件路径
OUTPUT_ROOT = Path(r"/home/qc/GAOSHIQING/ComfyUI/config/总类")    # 输出目录根路径
DRY_RUN = False


def sanitize_name(name: str) -> str:
    """将类目名转成安全的 Windows 文件夹名。"""
    cleaned = re.sub(WINDOWS_FORBIDDEN_CHARS, "_", name.strip())
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" .")
    return cleaned or "未命名"


def parse_md(md_path: Path) -> List[Tuple[str, str, str]]:
    """
    解析类目 Markdown，返回三元组列表:
    (level1, level2, level3)
    其中 level3 允许为空字符串（表示只有两层）。
    """
    lines = md_path.read_text(encoding="utf-8").splitlines()

    level1 = ""
    rows: List[Tuple[str, str, str]] = []

    level1_pattern = re.compile(r"^第[^\s:：]+大类[:：]\s*(.+)$")
    level2_with_children_pattern = re.compile(r"^([^:：]+)[:：]\s*(.+)$")

    for raw in lines:
        line = raw.strip()
        if not line:
            continue

        m1 = level1_pattern.match(line)
        if m1:
            level1 = sanitize_name(m1.group(1))
            continue

        if not level1:
            continue

        m2 = level2_with_children_pattern.match(line)
        if m2:
            level2 = sanitize_name(m2.group(1))
            rhs = m2.group(2).strip()
            level3_items = [
                sanitize_name(x)
                for x in re.split(r"[、，,]", rhs)
                if x.strip()
            ]
            for level3 in level3_items:
                rows.append((level1, level2, level3))
            continue

        # 兼容“只有二级类目，无三级展开”的行（如第七大类中的若干行）
        rows.append((level1, sanitize_name(line), ""))

    # 去重并保持首次出现顺序
    deduped: List[Tuple[str, str, str]] = []
    seen = set()
    for item in rows:
        if item in seen:
            continue
        seen.add(item)
        deduped.append(item)
    return deduped


def create_folders(rows: List[Tuple[str, str, str]], output_root: Path, dry_run: bool) -> None:
    level1_set = set()
    level2_set = set()
    level3_set = set()

    for level1, level2, level3 in rows:
        p1 = output_root / level1
        p2 = p1 / level2

        level1_set.add(p1)
        level2_set.add(p2)

        if not dry_run:
            p2.mkdir(parents=True, exist_ok=True)

        if level3:
            p3 = p2 / level3
            level3_set.add(p3)
            if not dry_run:
                p3.mkdir(parents=True, exist_ok=True)

    print(f"[INFO] 一级目录数量: {len(level1_set)}")
    print(f"[INFO] 二级目录数量: {len(level2_set)}")
    print(f"[INFO] 三级目录数量: {len(level3_set)}")
    print(f"[OK] 输出根目录: {output_root}")
    if dry_run:
        print("[OK] 仅预览（dry-run），未实际创建目录。")


def main() -> None:
    source_md = SOURCE_MD.resolve()
    output_root = OUTPUT_ROOT.resolve()

    if not source_md.exists():
        raise FileNotFoundError(f"未找到源文件: {source_md}")

    rows = parse_md(source_md)
    if not rows:
        raise RuntimeError("未解析到可创建的类目，请检查 Markdown 格式。")

    create_folders(rows, output_root, DRY_RUN)


if __name__ == "__main__":
    main()
