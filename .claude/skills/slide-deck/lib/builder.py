#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""
slide-deck builder — manifest YAML を Google Slides に変換する。

アーキテクチャ:
  Layer 1: 単位/色/Markdown ヘルパ
  Layer 2: Slides API リクエスト生成 (r_*)
  Layer 3: Style トークン (TextStyle dataclass)
  Layer 4: Block 抽象 (Text, Rect, Hrule, Vrule, Spacer)
  Layer 5: Container 抽象 (Stack, Row, Frame, Layer, Pos, Cell)
  Layer 6: コンポーネント (Header, Footer, Title, TakeawayBand, ExhibitCard, KvCell, ...)
  Layer 7: ページレンダラ — `[(block, x, y, w, h), ...]` を返す

設計方針:
  - vcenter は Cell/Stack の属性。個別 Text に毎回付ける必要は無い
  - 各ページレンダラは「絶対座標で並べたブロックのリスト」を返す（短く宣言的）
  - スタイルは TextStyle トークンで一元管理。Style だけ書き換えれば全箇所反映
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import uuid
from dataclasses import dataclass, field, replace
from pathlib import Path

import yaml


# ───────────────────────────────────────────────────────────────
# Layer 1: 単位・座標系・色・Markdown
# ───────────────────────────────────────────────────────────────
SCALE = 10.0 / 13.333
EMU_PER_INCH = 914400
PAGE_W = 13.333
PAGE_H = 7.5


def emu(spec_in: float) -> int:
    return int(spec_in * SCALE * EMU_PER_INCH)


def pt(n: float) -> dict:
    return {"magnitude": n, "unit": "PT"}


def hex_to_rgb(h: str) -> dict:
    h = h.lstrip("#")
    return {"red": int(h[0:2], 16) / 255,
            "green": int(h[2:4], 16) / 255,
            "blue": int(h[4:6], 16) / 255}


def new_id(prefix: str = "el") -> str:
    return f"{prefix}_{uuid.uuid4().hex[:10]}"


def parse_bold(text: str) -> tuple[str, list[tuple[int, int]]]:
    """`**bold**` を抽出。プレーン文字列とboldレンジを返す。"""
    parts: list[str] = []
    bolds: list[tuple[int, int]] = []
    i = 0
    plain_pos = 0
    while i < len(text):
        idx = text.find("**", i)
        if idx == -1:
            parts.append(text[i:]); break
        if idx > i:
            parts.append(text[i:idx]); plain_pos += idx - i
        close = text.find("**", idx + 2)
        if close == -1:
            parts.append(text[idx:]); break
        seg = text[idx + 2:close]
        parts.append(seg); bolds.append((plain_pos, plain_pos + len(seg)))
        plain_pos += len(seg); i = close + 2
    return "".join(parts), bolds


# Color tokens
COL = {
    "bg": "#FFFFFF", "text": "#0E0E0E", "text_sub": "#303030",
    "line_soft": "#D0D0D0", "line_strong": "#8A8A8A",
    "panel": "#2B2B2B", "panel_deep": "#0C0C0C", "on_panel": "#FFFFFF",
    "blue": "#182B90", "blue_light": "#7B8BD0", "blue_pale": "#E8EBF7",
    "gold": "#C3A763",
    "good": "#609C87", "bad": "#C00000",
}
FONT_JA = "Noto Sans JP"


def accent_of(deck: dict) -> str:
    return COL["gold"] if deck.get("accent") == "gold" else COL["blue"]


def accent_light_of(deck: dict) -> str:
    """暗背景上で識別性の高い accent variant"""
    return COL["gold"] if deck.get("accent") == "gold" else COL["blue_light"]


# ───────────────────────────────────────────────────────────────
# Layer 2: Slides API requests (低レベル, immutable)
# ───────────────────────────────────────────────────────────────
def _props(slide_id, x, y, w, h):
    return {
        "pageObjectId": slide_id,
        "size": {"width": {"magnitude": emu(w), "unit": "EMU"},
                 "height": {"magnitude": emu(h), "unit": "EMU"}},
        "transform": {"scaleX": 1, "scaleY": 1,
                      "translateX": emu(x), "translateY": emu(y), "unit": "EMU"},
    }


def r_create_slide(sid):
    return {"createSlide": {"objectId": sid, "slideLayoutReference": {"predefinedLayout": "BLANK"}}}


def r_text_box(sid, oid, x, y, w, h):
    return {"createShape": {"objectId": oid, "shapeType": "TEXT_BOX",
                            "elementProperties": _props(sid, x, y, w, h)}}


def r_rect(sid, oid, x, y, w, h):
    return {"createShape": {"objectId": oid, "shapeType": "RECTANGLE",
                            "elementProperties": _props(sid, x, y, w, h)}}


def r_line(sid, oid, x, y, w, h):
    p = _props(sid, x, y, w, h)
    p["size"]["width"]["magnitude"] = max(p["size"]["width"]["magnitude"], 1)
    p["size"]["height"]["magnitude"] = max(p["size"]["height"]["magnitude"], 1)
    return {"createLine": {"objectId": oid, "lineCategory": "STRAIGHT", "elementProperties": p}}


def r_insert(oid, text):
    return {"insertText": {"objectId": oid, "text": text, "insertionIndex": 0}}


def r_text_style(oid, *, size=None, bold=None, color=None, font=None, start=None, end=None):
    style, fields = {}, []
    if size is not None: style["fontSize"] = pt(size); fields.append("fontSize")
    if bold is not None: style["bold"] = bold; fields.append("bold")
    if color is not None:
        style["foregroundColor"] = {"opaqueColor": {"rgbColor": hex_to_rgb(color)}}
        fields.append("foregroundColor")
    if font is not None: style["fontFamily"] = font; fields.append("fontFamily")
    req = {"updateTextStyle": {"objectId": oid, "style": style, "fields": ",".join(fields)}}
    if start is not None and end is not None:
        req["updateTextStyle"]["textRange"] = {"type": "FIXED_RANGE", "startIndex": start, "endIndex": end}
    else:
        req["updateTextStyle"]["textRange"] = {"type": "ALL"}
    return req


def r_para_style(oid, *, align="START"):
    return {"updateParagraphStyle": {"objectId": oid, "style": {"alignment": align},
                                      "fields": "alignment", "textRange": {"type": "ALL"}}}


def r_shape_fill(oid, color):
    return {"updateShapeProperties": {"objectId": oid,
            "shapeProperties": {"shapeBackgroundFill": {"solidFill": {"color": {"rgbColor": hex_to_rgb(color)}}}},
            "fields": "shapeBackgroundFill.solidFill.color"}}


def r_shape_no_fill(oid):
    return {"updateShapeProperties": {"objectId": oid,
            "shapeProperties": {"shapeBackgroundFill": {"propertyState": "NOT_RENDERED"}},
            "fields": "shapeBackgroundFill.propertyState"}}


def r_shape_outline(oid, color, weight=0.75):
    return {"updateShapeProperties": {"objectId": oid,
            "shapeProperties": {"outline": {
                "outlineFill": {"solidFill": {"color": {"rgbColor": hex_to_rgb(color)}}},
                "weight": pt(weight)}},
            "fields": "outline.outlineFill,outline.weight"}}


def r_shape_no_outline(oid):
    return {"updateShapeProperties": {"objectId": oid,
            "shapeProperties": {"outline": {"propertyState": "NOT_RENDERED"}},
            "fields": "outline.propertyState"}}


def r_shape_vcenter(oid):
    return {"updateShapeProperties": {"objectId": oid,
            "shapeProperties": {"contentAlignment": "MIDDLE"},
            "fields": "contentAlignment"}}


def r_line_style(oid, color, weight=0.75):
    return {"updateLineProperties": {"objectId": oid,
            "lineProperties": {"lineFill": {"solidFill": {"color": {"rgbColor": hex_to_rgb(color)}}},
                                "weight": pt(weight)},
            "fields": "lineFill,weight"}}


def r_alt_text(oid, title, description=""):
    """要素に semantic name を埋め込む（後から API patch で検索可能）"""
    return {"updatePageElementAltText": {
        "objectId": oid, "title": title, "description": description}}


# ───────────────────────────────────────────────────────────────
# Layer 3: Style tokens
# ───────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class TextStyle:
    size: float = 11
    bold: bool = False
    color: str = COL["text"]
    font: str = FONT_JA
    align: str = "START"
    parse_md: bool = True

    def with_(self, **kw) -> "TextStyle":
        return replace(self, **kw)


# 重要：font_size pt → spec inch 換算には /SCALE が必要。
# pt=1/72 actual inch、spec inch = actual inch / SCALE なので 1pt = (1/72)/SCALE spec inch。

def line_height_in(style: TextStyle) -> float:
    """1行あたりの推定高さ (spec inch)。Slides 実描画 ~ size × 1.15。"""
    return style.size * 1.15 / 72 / SCALE


def char_width_in(style: TextStyle) -> float:
    """文字幅推定 (spec inch)。日本語/英字混在の平均。"""
    return style.size * (0.020 if style.bold else 0.0185) / SCALE


# Design tokens
S_HEADER_NAME = TextStyle(size=11, bold=True, parse_md=False)
S_HEADER_RUN = TextStyle(size=9, color=COL["text_sub"], align="END", parse_md=False)
S_HEADER_CHIP = TextStyle(size=11, bold=True, color=COL["on_panel"], align="CENTER", parse_md=False)

S_TITLE = TextStyle(size=22, bold=True, parse_md=True)
S_COVER_BIG = TextStyle(size=28, bold=True, parse_md=False)
S_SUBTITLE = TextStyle(size=14, color=COL["text_sub"], parse_md=False)
S_TAGLINE = TextStyle(size=10, color=COL["text_sub"], parse_md=False)

S_SUMMARY_SUPPORT = TextStyle(size=11, color=COL["text_sub"], parse_md=False)
S_TAKEAWAY = TextStyle(size=12, bold=True, color=COL["on_panel"], parse_md=True)
S_BULLET = TextStyle(size=11, parse_md=True)
S_IMPLICATION = TextStyle(size=10, bold=True, parse_md=False)

S_CARD_HEAD = TextStyle(size=12, bold=True, color=COL["on_panel"], parse_md=False)
S_CARD_BODY = TextStyle(size=10, parse_md=True)

S_EXHIBIT_LABEL = TextStyle(size=8, bold=True, parse_md=False)  # color = accent
S_EXHIBIT_TITLE = TextStyle(size=11, bold=True, parse_md=False)
S_EXHIBIT_TITLE_SM = TextStyle(size=10, bold=True, parse_md=False)
S_PLACEHOLDER = TextStyle(size=9, color=COL["line_soft"], align="CENTER", parse_md=False)
S_SOURCE = TextStyle(size=8, color=COL["text_sub"], parse_md=False)
S_SOURCE_SM = TextStyle(size=7, color=COL["text_sub"], parse_md=False)
S_NOTE = TextStyle(size=8, color=COL["text_sub"], align="END", parse_md=False)

S_REC_SUPPORT = TextStyle(size=12, parse_md=True)
S_REC_TAKEAWAY = TextStyle(size=12, bold=True, color=COL["on_panel"], parse_md=True)
S_EVIDENCE = TextStyle(size=10, bold=True, color=COL["text_sub"], parse_md=False)

S_TABLE_HEAD = TextStyle(size=10, bold=True, color=COL["on_panel"], parse_md=False)
S_TABLE_CELL = TextStyle(size=9, parse_md=False)
S_TABLE_CELL_SEVERE = TextStyle(size=9, bold=True, color=COL["bad"], parse_md=False)

S_KV_LABEL = TextStyle(size=9, color=COL["text_sub"], parse_md=False)
S_KV_VALUE = TextStyle(size=14, bold=True, parse_md=False)

S_FOOTER = TextStyle(size=8, color=COL["text_sub"], parse_md=False)
S_FOOTER_CENTER = TextStyle(size=8, color=COL["text_sub"], align="CENTER", parse_md=False)
S_FOOTER_RIGHT = TextStyle(size=8, color=COL["text_sub"], align="END", parse_md=False)

S_ROADMAP_PHASE = TextStyle(size=11, bold=True, parse_md=False)
S_ROADMAP_PERIOD = TextStyle(size=8, color=COL["text_sub"], parse_md=False)
S_ROADMAP_MARK = TextStyle(size=8, color=COL["text_sub"], align="CENTER", parse_md=False)


# ───────────────────────────────────────────────────────────────
# Layer 4: Block primitives
# ───────────────────────────────────────────────────────────────
@dataclass
class Ctx:
    reqs: list
    sid: str
    deck: dict
    page_no: int = 0


def _qualify_name(ctx: Ctx, name: str) -> str:
    """slide_idx を prefix にした unique name を返す: 's3.exhibit_1.title'"""
    return f"s{ctx.page_no}.{name}"


class Block:
    """Block protocol。measure(w) は推奨高さ、emit(ctx,x,y,w,h) で描画。"""
    def measure(self, w: float) -> float:
        return 0
    def emit(self, ctx: Ctx, x: float, y: float, w: float, h: float):
        pass


@dataclass
class Text(Block):
    text: str = ""
    style: TextStyle = field(default_factory=lambda: TextStyle())
    vcenter: bool = False
    fixed_h: float | None = None
    name: str | None = None  # alt-text 名（後の patch 用）

    def measure(self, w):
        if self.fixed_h is not None: return self.fixed_h
        if not self.text: return 0
        cw = char_width_in(self.style)
        chars_per_line = max(1, int(w / cw))
        lines = max(1, (len(self.text) + chars_per_line - 1) // chars_per_line)
        return lines * line_height_in(self.style)

    def emit(self, ctx, x, y, w, h):
        oid = new_id("tx")
        ctx.reqs.append(r_text_box(ctx.sid, oid, x, y, w, h))
        if self.name:
            ctx.reqs.append(r_alt_text(oid, _qualify_name(ctx, self.name)))
        if self.vcenter:
            ctx.reqs.append(r_shape_vcenter(oid))
        if not self.text:
            return
        plain, bolds = parse_bold(self.text) if self.style.parse_md else (self.text, [])
        ctx.reqs.append(r_insert(oid, plain))
        ctx.reqs.append(r_text_style(oid, size=self.style.size, bold=self.style.bold,
                                       color=self.style.color, font=self.style.font))
        ctx.reqs.append(r_para_style(oid, align=self.style.align))
        for s, e in bolds:
            ctx.reqs.append(r_text_style(oid, bold=True, start=s, end=e))


@dataclass
class Rect(Block):
    fill: str | None = None
    border: str | None = None
    border_pt: float = 0.75
    fixed_h: float | None = None
    name: str | None = None

    def measure(self, w):
        return self.fixed_h or 0

    def emit(self, ctx, x, y, w, h):
        oid = new_id("rc")
        ctx.reqs.append(r_rect(ctx.sid, oid, x, y, w, h))
        if self.name:
            ctx.reqs.append(r_alt_text(oid, _qualify_name(ctx, self.name)))
        ctx.reqs.append(r_shape_fill(oid, self.fill) if self.fill else r_shape_no_fill(oid))
        ctx.reqs.append(r_shape_outline(oid, self.border, self.border_pt) if self.border else r_shape_no_outline(oid))


@dataclass
class HRule(Block):
    color: str = field(default_factory=lambda: COL["line_soft"])
    weight: float = 0.75

    def measure(self, w):
        return 0.02

    def emit(self, ctx, x, y, w, h):
        oid = new_id("ln")
        ctx.reqs.append(r_line(ctx.sid, oid, x, y, w, 0))
        ctx.reqs.append(r_line_style(oid, self.color, self.weight))


@dataclass
class VRule(Block):
    color: str = field(default_factory=lambda: COL["line_soft"])
    weight: float = 0.75
    fixed_h: float | None = None

    def measure(self, w):
        return self.fixed_h or 0

    def emit(self, ctx, x, y, w, h):
        oid = new_id("ln")
        ctx.reqs.append(r_line(ctx.sid, oid, x, y, 0, h))
        ctx.reqs.append(r_line_style(oid, self.color, self.weight))


@dataclass
class Spacer(Block):
    h: float = 0

    def measure(self, w): return self.h
    def emit(self, ctx, x, y, w, h): pass


@dataclass
class Flex(Block):
    """Stack 内で残余 height を吸収するラッパ。複数あれば等分。"""
    content: Block | None = None

    def measure(self, w):
        return 0  # Stack 側で特別扱い

    def emit(self, ctx, x, y, w, h):
        if self.content:
            self.content.emit(ctx, x, y, w, h)


# ───────────────────────────────────────────────────────────────
# Layer 5: Containers
# ───────────────────────────────────────────────────────────────
@dataclass
class Stack(Block):
    """子を縦方向に並べる。vcenter=True で残余を上下均等に配分。"""
    children: list = field(default_factory=list)
    gap: float = 0
    vcenter: bool = False
    fixed_h: float | None = None

    def measure(self, w):
        if self.fixed_h is not None: return self.fixed_h
        total = sum(c.measure(w) for c in self.children)
        total += self.gap * max(0, len(self.children) - 1)
        return total

    def emit(self, ctx, x, y, w, h):
        flex_idxs = [i for i, c in enumerate(self.children) if isinstance(c, Flex)]
        sizes = []
        fixed_total = 0
        for c in self.children:
            m = 0 if isinstance(c, Flex) else c.measure(w)
            sizes.append(m); fixed_total += m
        gap_total = self.gap * max(0, len(self.children) - 1)
        if flex_idxs:
            remaining = max(0, h - fixed_total - gap_total)
            per = remaining / len(flex_idxs)
            for i in flex_idxs: sizes[i] = per
            cy = y
        else:
            content_h = fixed_total + gap_total
            cy = y + max(0, (h - content_h) / 2) if self.vcenter else y
        for i, c in enumerate(self.children):
            c.emit(ctx, x, cy, w, sizes[i])
            cy += sizes[i] + (self.gap if i < len(self.children) - 1 else 0)


@dataclass
class Frame(Block):
    """Rect (背景・枠線) + 内側 padding を含む content"""
    content: Block | None = None
    fill: str | None = None
    border: str | None = None
    border_pt: float = 0.75
    pad: float = 0.18
    pad_x: float | None = None
    pad_y: float | None = None
    fixed_h: float | None = None

    def _pad(self):
        return (self.pad_x if self.pad_x is not None else self.pad,
                self.pad_y if self.pad_y is not None else self.pad)

    def measure(self, w):
        if self.fixed_h is not None: return self.fixed_h
        px, py = self._pad()
        ch = self.content.measure(w - 2 * px) if self.content else 0
        return ch + 2 * py

    def emit(self, ctx, x, y, w, h):
        Rect(fill=self.fill, border=self.border, border_pt=self.border_pt).emit(ctx, x, y, w, h)
        if self.content:
            px, py = self._pad()
            self.content.emit(ctx, x + px, y + py, w - 2 * px, h - 2 * py)


@dataclass
class Layer(Block):
    """同一矩形に複数子を重ねる (描画順 = z-order, 後が手前)"""
    children: list = field(default_factory=list)
    fixed_h: float | None = None

    def measure(self, w):
        if self.fixed_h is not None: return self.fixed_h
        return max((c.measure(w) for c in self.children), default=0)

    def emit(self, ctx, x, y, w, h):
        for c in self.children:
            c.emit(ctx, x, y, w, h)


@dataclass
class Pos(Block):
    """親の左上を起点とした相対座標で子を配置"""
    content: Block | None = None
    dx: float = 0
    dy: float = 0
    dw: float | None = None  # None なら親幅
    dh: float | None = None  # None なら親高

    def measure(self, w):
        return self.dh or 0

    def emit(self, ctx, x, y, w, h):
        cw = self.dw if self.dw is not None else (w - self.dx)
        ch = self.dh if self.dh is not None else (h - self.dy)
        if self.content:
            self.content.emit(ctx, x + self.dx, y + self.dy, cw, ch)


@dataclass
class Cell(Block):
    """固定サイズのセル。中身を vcenter/halign で配置。"""
    content: Block | None = None
    fixed_h: float | None = None
    vcenter: bool = False
    halign: str = "left"  # 子側 align 任せのため未使用

    def measure(self, w):
        return self.fixed_h or (self.content.measure(w) if self.content else 0)

    def emit(self, ctx, x, y, w, h):
        if not self.content: return
        ch = self.content.measure(w)
        cy = y + max(0, (h - ch) / 2) if self.vcenter else y
        self.content.emit(ctx, x, cy, w, ch if self.vcenter else h)


# ───────────────────────────────────────────────────────────────
# Layer 6: Components
# ───────────────────────────────────────────────────────────────
def Header(deck, slide) -> Block:
    """y=0.18 / h=0.36, 下に水平線 (y=0.62)"""
    no = slide.get("section_no", "") or ""
    name = slide.get("section_name", "") or ""
    title = deck.get("title", "")
    children = []
    if no:
        children.append(Pos(Frame(Text(no, S_HEADER_CHIP, vcenter=True, name="header.chip"),
                                    fill=COL["panel"], pad_x=0.12, pad_y=0.04),
                            0.60, 0, 0.92, 0.36))
    if name:
        children.append(Pos(Text(name, S_HEADER_NAME, vcenter=True, name="header.section_name"),
                            1.62, 0, 5.0, 0.36))
    if title:
        children.append(Pos(Cell(Text(title, S_HEADER_RUN, vcenter=True), vcenter=True),
                            7.0, 0, 5.91, 0.36))
    children.append(Pos(HRule(COL["line_soft"], 0.75), 0.60, 0.44, 12.31, 0))
    return Layer(children, fixed_h=0.62)


def Footer(deck, page_no) -> Block:
    """y=6.95, 上に細い水平線、3カラム情報"""
    left = " / ".join([p for p in [deck.get("date"), deck.get("confidentiality")] if p])
    year = (deck.get("date") or "20XX")[:4]
    company = deck.get("client") or ""
    return Layer([
        Pos(HRule(COL["line_soft"], 0.5), 0, 0, PAGE_W, 0),
        Pos(Text(left, S_FOOTER), 0.60, 0.10, 4.0, 0.30),
        Pos(Text(f"© {year} {company}", S_FOOTER_CENTER), 4.66, 0.10, 4.0, 0.30),
        Pos(Text(str(page_no), S_FOOTER_RIGHT), 8.91, 0.10, 4.0, 0.30),
    ], fixed_h=0.55)


def Title(text: str) -> Block:
    """y=0.78, h=1.00 の縦中央配置"""
    return Cell(Text(text, S_TITLE, vcenter=True, name="title"), vcenter=True, fixed_h=1.00)


def TakeawayBand(text: str) -> Block:
    return Frame(Cell(Text(text, S_TAKEAWAY, vcenter=True), vcenter=True),
                 fill=COL["panel"], pad_x=0.20, pad_y=0.05, fixed_h=0.50)


def ExhibitCard(label: str, title: str, deck: dict, *, show_placeholder: bool = True) -> Block:
    """McKスタイル: [EXHIBIT N] (accent) / Title (bold) / ──── / [chart placeholder]"""
    accent = accent_of(deck)
    label_style = S_EXHIBIT_LABEL.with_(color=accent)
    children: list[Block] = []
    if label:
        children.append(Text(label.upper(), label_style, fixed_h=0.20))
        children.append(Spacer(0.04))
    if title:
        # 幅で title size 切替（狭枠は 10pt）
        title_style = S_EXHIBIT_TITLE  # 11pt
        children.append(Text(title, title_style))
        children.append(Spacer(0.12))  # 文字下端と rule の余白
    children.append(HRule(COL["line_strong"], 0.75))
    children.append(Spacer(0.10))
    # 残余領域：placeholder（あるとき）または空白（無いとき）
    if show_placeholder:
        children.append(Flex(Cell(
            Text("［Chart / data placeholder — insert visual］", S_PLACEHOLDER, vcenter=True),
            vcenter=True)))
    else:
        children.append(Flex())
    return Frame(Stack(children, gap=0), fill=COL["bg"], border=COL["line_soft"],
                  pad_x=0.14, pad_y=0.12)


def ExhibitWithSource(label: str, title: str, source: str | None, notes: str | None,
                      deck: dict, *, show_placeholder: bool = True,
                      x: float, y: float, w: float, h: float) -> list:
    """Exhibit枠 + 枠下 source/notes をまとめて返す `(block, x, y, w, h)` のリスト"""
    blocks = [(ExhibitCard(label, title, deck, show_placeholder=show_placeholder), x, y, w, h)]
    show_notes = bool(notes) and w >= 4.0
    src_w = w * 0.60 if show_notes else w * 0.98
    src_style = S_SOURCE_SM if w < 4.0 else S_SOURCE
    if source:
        blocks.append((Text(f"Source: {source}", src_style), x, y + h + 0.04, src_w, 0.22))
    if show_notes:
        blocks.append((Text(f"Note: {notes}", S_NOTE), x + src_w, y + h + 0.04, w - src_w, 0.22))
    return blocks


def Card(num: str, heading: str, body: str, deck: dict) -> Block:
    """KeyFindings カード: 黒帯 (番号 + 見出し) + 白本文"""
    band = Frame(Layer([
        Pos(Cell(Text(num, S_HEADER_CHIP.with_(color=accent_light_of(deck), align="START"),
                        vcenter=True), vcenter=True), 0.14, 0, 0.70, 0.55),
        Pos(Cell(Text(heading, S_CARD_HEAD, vcenter=True), vcenter=True), 0.90, 0, None, 0.55),
    ]), fill=COL["panel"], pad=0, fixed_h=0.55)
    body_block = Frame(Cell(Text(body, S_CARD_BODY, vcenter=True), vcenter=True),
                       fill=COL["bg"], border=COL["line_soft"], pad_x=0.18, pad_y=0.16)
    return Stack([band, Flex(body_block)])


def KvCell(label: str, value: str, deck: dict, *, cell_h: float = 0.80) -> Block:
    """K-V セル: 左に縦アクセントバー + label/value を視覚高さで縦中央配置。"""
    accent = accent_of(deck)
    # spec inch での視覚高さ (font_size × 1.15 / 72 / SCALE)
    label_visual = 0.20  # 9pt
    value_visual = 0.30  # 14pt bold
    gap = 0.05
    visual_content_h = label_visual + gap + value_visual  # 0.55
    cy_off = max(0, (cell_h - visual_content_h) / 2)
    # text box は visual より少し大きめに（クリップ防止）
    label_box_h = label_visual + 0.04
    value_box_h = value_visual + 0.04
    rail_h = min(0.60, cell_h - 0.20)
    rail_y = (cell_h - rail_h) / 2
    return Layer([
        Pos(VRule(accent, 2.5, fixed_h=rail_h), 0, rail_y, 0, rail_h),
        Pos(Text(label, S_KV_LABEL), 0.20, cy_off, None, label_box_h),
        Pos(Text(value, S_KV_VALUE), 0.20, cy_off + label_visual + gap, None, value_box_h),
    ], fixed_h=cell_h)


# ───────────────────────────────────────────────────────────────
# レイアウト共通領域 (named regions)
# ───────────────────────────────────────────────────────────────
HEADER_REGION = (0, 0, PAGE_W, 0.62)
TITLE_REGION = (0.60, 0.78, 12.31, 1.00)
FOOTER_REGION = (0, 6.95, PAGE_W, 0.55)


# ───────────────────────────────────────────────────────────────
# Layer 7: Page renderers — list of (block, x, y, w, h)
# ───────────────────────────────────────────────────────────────
def render_cover(slide, deck, page_no):
    accent = accent_of(deck)
    blocks = [
        (Rect(fill=accent), 11.30, 0, PAGE_W - 11.30, PAGE_H),
        (Rect(fill=accent), 0, 0, 11.30, 0.10),
        (Cell(Text(slide.get("big_title", ""), S_COVER_BIG, vcenter=True), vcenter=True),
         0.60, 2.30, 10.5, 1.50),
        (HRule(accent, 3.0), 0.60, 3.95, 1.20, 0),
    ]
    if slide.get("subtitle"):
        blocks.append((Text(slide["subtitle"], S_SUBTITLE), 0.60, 4.10, 10.5, 0.45))
    tagline = slide.get("tagline") or "With Narrative Intelligence"
    blocks.append((Text(tagline, S_TAGLINE), 0.60, 4.65, 10.5, 0.30))
    # 黒帯フッター
    blocks.append((Rect(fill=COL["panel_deep"]), 0, 6.55, 11.30, 0.95))
    meta = " / ".join([p for p in [deck.get("client"), deck.get("date"), deck.get("confidentiality")] if p])
    blocks.append((Text(meta, TextStyle(size=10, bold=True, color=COL["on_panel"], parse_md=False)),
                   0.60, 6.78, 10.5, 0.25))
    if deck.get("project_code"):
        blocks.append((Text(deck["project_code"], TextStyle(size=8, color=COL["line_soft"], parse_md=False),
                            name="cover.project_code"),
                       0.60, 7.08, 10.5, 0.25))
    return blocks


def render_exec_summary(slide, deck, page_no):
    blocks = [
        (Header(deck, slide), *HEADER_REGION),
        (Title(slide.get("title", "")), *TITLE_REGION),
    ]
    if slide.get("takeaway"):
        blocks.append((TakeawayBand(slide["takeaway"]), 0.60, 1.90, 12.31, 0.50))
    # bullets
    by = 2.55
    for b in (slide.get("bullets") or [])[:3]:
        blocks.append((Cell(Text("—  " + b, S_BULLET, vcenter=True), vcenter=True),
                       0.80, by, 12.0, 0.40))
        by += 0.40
    # exhibits
    exhibits = (slide.get("exhibits") or [])[:3]
    ex_y, ex_h = 3.95, 2.10
    if len(exhibits) >= 1:
        blocks += ExhibitWithSource(exhibits[0]["label"], exhibits[0]["title"],
                                     exhibits[0].get("source"), exhibits[0].get("notes"),
                                     deck, x=0.60, y=ex_y, w=6.20, h=ex_h)
    right_x, right_w = 7.05, 5.86
    if len(exhibits) == 2:
        blocks += ExhibitWithSource(exhibits[1]["label"], exhibits[1]["title"],
                                     exhibits[1].get("source"), exhibits[1].get("notes"),
                                     deck, x=right_x, y=ex_y, w=right_w, h=ex_h)
    elif len(exhibits) >= 3:
        col_w = (right_w - 0.20) / 2
        for i in (1, 2):
            cx = right_x if i == 1 else right_x + col_w + 0.20
            blocks += ExhibitWithSource(exhibits[i]["label"], exhibits[i]["title"],
                                         exhibits[i].get("source"), exhibits[i].get("notes"),
                                         deck, x=cx, y=ex_y, w=col_w, h=ex_h)
    # implications
    impls = (slide.get("implications") or [])[:2]
    if impls:
        blocks.append((HRule(COL["line_strong"], 1.0), 0.60, 6.45, 12.31, 0))
        cell_w = 12.0 / max(len(impls), 1)
        for i, imp in enumerate(impls):
            blocks.append((Cell(Text("▶  " + imp, S_IMPLICATION, vcenter=True), vcenter=True),
                           0.80 + i * cell_w, 6.55, cell_w - 0.20, 0.35))
    blocks.append((Footer(deck, page_no), *FOOTER_REGION))
    return blocks


def render_key_findings(slide, deck, page_no):
    blocks = [
        (Header(deck, slide), *HEADER_REGION),
        (Title(slide.get("title", "")), *TITLE_REGION),
    ]
    if slide.get("summary_support"):
        blocks.append((Text(slide["summary_support"], S_SUMMARY_SUPPORT), 0.60, 1.85, 12.31, 0.35))
    cards = (slide.get("cards") or [])[:5]
    n = len(cards)
    base_y = 2.40
    avail_h = (5.40 - base_y) if n <= 3 else (6.40 - base_y)
    if n <= 3:
        col_w = (12.31 - 0.20 * (n - 1)) / max(n, 1)
        coords = [(i, 0) for i in range(n)]; row_h = avail_h
    elif n == 4:
        col_w = (12.31 - 0.20) / 2; row_h = (avail_h - 0.20) / 2
        coords = [(0,0),(1,0),(0,1),(1,1)]
    else:
        col_w = (12.31 - 0.20 * 2) / 3; row_h = (avail_h - 0.20) / 2
        coords = [(0,0),(1,0),(2,0),(0.5,1),(1.5,1)]
    for c, (col, row) in zip(cards, coords):
        cx = 0.60 + col * (col_w + 0.20)
        cy = base_y + row * (row_h + 0.20)
        num = c.get("num") or c.get(False) or c.get("no") or ""
        blocks.append((Card(str(num), c.get("heading", ""), c.get("body", ""), deck),
                       cx, cy, col_w, row_h))
    blocks.append((Footer(deck, page_no), *FOOTER_REGION))
    return blocks


def render_recommendation(slide, deck, page_no):
    blocks = [
        (Header(deck, slide), *HEADER_REGION),
        (Title(slide.get("title", "")), *TITLE_REGION),
    ]
    if slide.get("takeaway"):
        blocks.append((TakeawayBand(slide["takeaway"]), 0.60, 1.90, 12.31, 0.50))
    sy = 2.70
    for s in (slide.get("supports") or [])[:3]:
        blocks.append((VRule(COL["blue"], 3.0, fixed_h=0.95), 0.62, sy + 0.05, 0, 0.95))
        blocks.append((Cell(Text(s, S_REC_SUPPORT, vcenter=True), vcenter=True),
                       0.85, sy, 11.5, 0.95))
        sy += 1.10
    refs = slide.get("evidence_refs") or []
    if refs:
        blocks.append((HRule(COL["line_soft"], 0.5), 0.60, 6.20, 12.31, 0))
        blocks.append((Text("Evidence: " + ", ".join(refs), S_EVIDENCE),
                       0.60, 6.30, 12.31, 0.35))
    blocks.append((Footer(deck, page_no), *FOOTER_REGION))
    return blocks


def render_risks(slide, deck, page_no):
    blocks = [
        (Header(deck, slide), *HEADER_REGION),
        (Title(slide.get("title", "")), *TITLE_REGION),
    ]
    headers = ["Risk", "Impact", "Likelihood", "Mitigation", "Owner"]
    col_w = [4.20, 1.30, 1.50, 4.21, 1.10]
    x_starts = [0.60]
    for w in col_w[:-1]:
        x_starts.append(x_starts[-1] + w)
    y, head_h, row_h = 2.10, 0.45, 0.70
    blocks.append((Rect(fill=COL["panel"]), 0.60, y, sum(col_w), head_h))
    for i, hd in enumerate(headers):
        blocks.append((Cell(Text(hd, S_TABLE_HEAD, vcenter=True), vcenter=True),
                       x_starts[i] + 0.12, y, col_w[i] - 0.20, head_h))
    ry = y + head_h
    for r in (slide.get("rows") or [])[:6]:
        cells = [r.get("risk",""), r.get("impact",""), r.get("likelihood",""),
                 r.get("mitigation",""), r.get("owner","")]
        for i, val in enumerate(cells):
            cell_style = S_TABLE_CELL_SEVERE if (r.get("severe") and i == 0) else S_TABLE_CELL
            blocks.append((Cell(Text(str(val), cell_style, vcenter=True), vcenter=True),
                           x_starts[i] + 0.12, ry, col_w[i] - 0.20, row_h))
        blocks.append((HRule(COL["line_soft"], 0.5), 0.60, ry + row_h, sum(col_w), 0))
        ry += row_h
    blocks.append((Footer(deck, page_no), *FOOTER_REGION))
    return blocks


def render_appendix(slide, deck, page_no):
    ex = slide.get("exhibit") or {}
    label = ex.get("label", "")
    title = ex.get("title", "")
    accent = accent_of(deck)
    fields = ex.get("fields") or []
    frame_x, frame_y = 0.60, 2.30
    frame_w, frame_h = 12.31, 4.00
    blocks = [
        (Header(deck, slide), *HEADER_REGION),
        (Title(f"{label} — {title}" if label and title else (title or label)), *TITLE_REGION),
        (Rect(fill=COL["bg"], border=COL["line_soft"]), frame_x, frame_y, frame_w, frame_h),
    ]
    if fields:
        cols = 2
        rows_n = (len(fields) + cols - 1) // cols
        pad_x, pad_y, col_gap = 0.50, 0.40, 0.40
        cell_w = (frame_w - 2 * pad_x - col_gap) / cols
        cell_h = (frame_h - 2 * pad_y) / rows_n
        for i, f in enumerate(fields):
            col = i % cols; row = i // cols
            cx = frame_x + pad_x + col * (cell_w + col_gap)
            cy = frame_y + pad_y + row * cell_h
            blocks.append((KvCell(f.get("label", ""), f.get("value", ""), deck, cell_h=cell_h),
                           cx, cy, cell_w, cell_h))
    elif ex.get("notes"):
        blocks.append((Text(ex["notes"], TextStyle(size=11, parse_md=True)),
                       frame_x + 0.20, frame_y + 0.30, frame_w - 0.40, frame_h - 0.50))
    if ex.get("source"):
        blocks.append((Text(f"Source: {ex['source']}", S_SOURCE),
                       frame_x, frame_y + frame_h + 0.04, frame_w, 0.22))
    blocks.append((Footer(deck, page_no), *FOOTER_REGION))
    return blocks


def _phase_week(s, default=None):
    if s is None: return default
    m = re.search(r'(\d+)', str(s))
    return int(m.group(1)) if m else default


def _short_week(s):
    return re.sub(r'Week\s*', 'W', str(s)) if s else ""


def render_roadmap(slide, deck, page_no):
    blocks = [
        (Header(deck, slide), *HEADER_REGION),
        (Title(slide.get("title", "")), *TITLE_REGION),
    ]
    phases = (slide.get("phases") or [])[:5]
    if not phases:
        blocks.append((Footer(deck, page_no), *FOOTER_REGION))
        return blocks
    weeks = []
    for ph in phases:
        s_w = _phase_week(ph.get("start"), 1)
        e_w = _phase_week(ph.get("end"), s_w + 2)
        if e_w <= s_w: e_w = s_w + 1
        weeks.append((s_w, e_w))
    max_w = max(e for _, e in weeks)
    min_w = min(s for s, _ in weeks)
    span = max_w - min_w + 1
    name_w = 2.40
    bar_x = 0.60 + name_w + 0.20
    bar_w = 12.91 - bar_x
    n = len(phases)
    band_top, band_bot = 2.30, 5.90
    row_h = (band_bot - band_top) / n
    accent_color = COL["blue"]
    soft_blue = COL["blue_pale"]
    # 軸ライン + マーカー
    axis_y = band_top - 0.10
    blocks.append((HRule(COL["line_soft"], 0.5), bar_x, axis_y, bar_w, 0))
    marker_weeks = sorted(set([min_w, max_w] + [int(min_w + span * 0.33), int(min_w + span * 0.67)]))
    for w_n in marker_weeks:
        mx = bar_x + (w_n - min_w) / span * bar_w
        blocks.append((VRule(COL["line_strong"], 0.5, fixed_h=0.10), mx, axis_y - 0.05, 0, 0.10))
        blocks.append((Text(f"W{w_n}", S_ROADMAP_MARK), mx - 0.5, axis_y - 0.30, 1.0, 0.20))
    for i, (ph, (s_w, e_w)) in enumerate(zip(phases, weeks)):
        ry = band_top + i * row_h
        blocks.append((Cell(Text(ph.get("name", ""), S_ROADMAP_PHASE, vcenter=True), vcenter=True),
                       0.60, ry + row_h * 0.20, name_w, row_h * 0.6))
        bar_h = 0.32
        bar_y = ry + (row_h - bar_h) / 2
        bx = bar_x + (s_w - min_w) / span * bar_w
        bw = (e_w - s_w + 1) / span * bar_w
        fill = accent_color if ph.get("critical") else soft_blue
        blocks.append((Rect(fill=fill), bx, bar_y, bw, bar_h))
        period = f"{_short_week(ph.get('start',''))} – {_short_week(ph.get('end',''))}".strip(" –")
        if period:
            blocks.append((Text(period, S_ROADMAP_PERIOD), bx, bar_y + bar_h + 0.06, max(bw, 1.0), 0.25))
    ms = slide.get("milestones") or []
    if ms:
        ms_text = "  ◆  ".join([f"{m.get('date','')}: {m.get('label','')}" for m in ms])
        blocks.append((Text("Milestones: " + ms_text, TextStyle(size=10, parse_md=False)),
                       0.60, band_bot + 0.20, 12.31, 0.35))
    if slide.get("notes_footer"):
        blocks.append((Text(slide["notes_footer"], S_FOOTER), 0.60, 6.55, 12.31, 0.30))
    blocks.append((Footer(deck, page_no), *FOOTER_REGION))
    return blocks


def render_options(slide, deck, page_no):
    blocks = [
        (Header(deck, slide), *HEADER_REGION),
        (Title(slide.get("title", "")), *TITLE_REGION),
    ]
    axes = slide.get("axes") or []
    a = slide.get("option_a") or {}
    b = slide.get("option_b") or {}
    accent_color = accent_of(deck)
    col_w = (12.31 - 0.20) / 2
    head_y = 2.10
    blocks.append((Frame(Cell(Text(a.get("name", "Option A"),
                                    TextStyle(size=12, bold=True, color=COL["on_panel"], align="CENTER"),
                                    vcenter=True), vcenter=True),
                          fill=COL["panel"], pad_x=0.18, pad_y=0.10),
                   0.60, head_y, col_w, 0.45))
    blocks.append((Frame(Cell(Text(b.get("name", "Option B"),
                                    TextStyle(size=12, bold=True, color=COL["on_panel"], align="CENTER"),
                                    vcenter=True), vcenter=True),
                          fill=COL["panel"], pad_x=0.18, pad_y=0.10),
                   0.80 + col_w, head_y, col_w, 0.45))
    if a.get("recommended"):
        blocks.append((HRule(accent_color, 2.5), 0.60, head_y + 0.50, 1.5, 0))
    if b.get("recommended"):
        blocks.append((HRule(accent_color, 2.5), 0.80 + col_w, head_y + 0.50, 1.5, 0))
    ry = head_y + 0.65
    row_h = (6.20 - ry) / max(len(axes), 1)
    for i, axis in enumerate(axes):
        blocks.append((Text(axis, TextStyle(size=9, color=COL["text_sub"], parse_md=False)),
                       0.60, ry, 12.31, 0.20))
        cells_a = a.get("cells") or []
        cells_b = b.get("cells") or []
        cell_a = cells_a[i] if i < len(cells_a) else ""
        cell_b = cells_b[i] if i < len(cells_b) else ""
        blocks.append((Frame(Cell(Text(cell_a, TextStyle(size=11, parse_md=True), vcenter=True), vcenter=True),
                              fill=COL["bg"], border=COL["line_soft"], border_pt=0.5, pad_x=0.18, pad_y=0.10),
                       0.60, ry + 0.22, col_w, row_h - 0.32))
        blocks.append((Frame(Cell(Text(cell_b, TextStyle(size=11, parse_md=True), vcenter=True), vcenter=True),
                              fill=COL["bg"], border=COL["line_soft"], border_pt=0.5, pad_x=0.18, pad_y=0.10),
                       0.80 + col_w, ry + 0.22, col_w, row_h - 0.32))
        ry += row_h
    blocks.append((Footer(deck, page_no), *FOOTER_REGION))
    return blocks


def render_pyramid(slide, deck, page_no):
    blocks = [
        (Header(deck, slide), *HEADER_REGION),
        (Title(slide.get("title", "")), *TITLE_REGION),
        (Frame(Cell(Text(slide.get("top_conclusion", ""),
                          TextStyle(size=13, bold=True, color=COL["on_panel"], parse_md=True),
                          vcenter=True), vcenter=True),
                fill=COL["panel"], pad_x=0.20, pad_y=0.13),
         0.60, 2.00, 12.31, 0.55),
    ]
    mids = (slide.get("middle_supports") or [])[:3]
    if mids:
        nm = len(mids)
        mw = (12.31 - 0.20 * (nm - 1)) / nm
        my = 2.85
        for i, m in enumerate(mids):
            mx = 0.60 + i * (mw + 0.20)
            blocks.append((Frame(Cell(Text(m, TextStyle(size=11, parse_md=True), vcenter=True), vcenter=True),
                                  fill=COL["bg"], border=COL["line_soft"], pad_x=0.18, pad_y=0.18),
                           mx, my, mw, 1.30))
    facts = (slide.get("bottom_facts") or [])[:2]
    fy = 4.50
    if len(facts) == 1:
        blocks += ExhibitWithSource(facts[0]["label"], facts[0].get("title", ""),
                                     facts[0].get("source"), facts[0].get("notes"),
                                     deck, x=0.60, y=fy + 0.30, w=12.31, h=1.50)
    elif len(facts) == 2:
        for i, f in enumerate(facts):
            fx = 0.60 + i * 6.25
            blocks += ExhibitWithSource(f["label"], f.get("title", ""), f.get("source"),
                                         f.get("notes"), deck, x=fx, y=fy + 0.30, w=6.06, h=1.50)
    blocks.append((Footer(deck, page_no), *FOOTER_REGION))
    return blocks


def render_generic(slide, deck, page_no):
    body_lines = []
    for k, v in slide.items():
        if k in ("layout", "title", "section_no", "section_name", "notes"): continue
        body_lines.append(f"{k}: {v}")
    return [
        (Header(deck, slide), *HEADER_REGION),
        (Title(slide.get("title", slide.get("layout", ""))), *TITLE_REGION),
        (Text("\n".join(body_lines), TextStyle(size=10, parse_md=False)), 0.60, 2.00, 12.31, 4.50),
        (Footer(deck, page_no), *FOOTER_REGION),
    ]


RENDERERS = {
    "Cover_Consulting": render_cover,
    "ExecSummary_1pager": render_exec_summary,
    "KeyFindings_MECE_3to5": render_key_findings,
    "Rec_Recommendation": render_recommendation,
    "Risks_Mitigations_Table": render_risks,
    "Appendix_Exhibits": render_appendix,
    "Roadmap_Gantt_Light": render_roadmap,
    "Options_2col_Tradeoff": render_options,
    "Pyramid_Principle": render_pyramid,
}


# ───────────────────────────────────────────────────────────────
# Validation / gws / main
# ───────────────────────────────────────────────────────────────
def validate(manifest: dict) -> list[str]:
    errors = []
    deck = manifest.get("deck", {})
    accent = deck.get("accent", "blue")
    if accent not in ("blue", "gold"):
        errors.append(f"deck.accent must be 'blue' or 'gold' (got {accent!r})")
    for i, s in enumerate(manifest.get("slides", []), 1):
        prefix = f"slide#{i} ({s.get('layout')})"
        title = s.get("title", "")
        if title and any(x in title for x in ["について", "の概要", "とは"]):
            errors.append(f"WARN {prefix}: 説明タイトル禁止『{title}』")
        if s.get("layout") == "ExecSummary_1pager":
            if len(s.get("bullets") or []) > 3:
                errors.append(f"{prefix}: bullets は最大3")
            if len(s.get("exhibits") or []) > 3:
                errors.append(f"{prefix}: exhibits は最大3")
            for e in s.get("exhibits") or []:
                if not e.get("source"):
                    errors.append(f"{prefix}: exhibit '{e.get('label','?')}' に source 必須")
    return errors


def gws(args, json_payload=None):
    cmd = ["gws"] + args + ["--format", "json"]
    if json_payload is not None:
        cmd += ["--json", json.dumps(json_payload)]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(f"gws error: {res.stderr}\n"); sys.exit(1)
    if not res.stdout.strip(): return {}
    return json.loads(res.stdout)


def create_presentation(title):
    return gws(["slides", "presentations", "create"], {"title": title})["presentationId"]


def batch_update(pid, requests):
    BATCH = 200
    for i in range(0, len(requests), BATCH):
        gws(["slides", "presentations", "batchUpdate", "--params",
             json.dumps({"presentationId": pid})], {"requests": requests[i:i+BATCH]})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest", type=Path)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--tag", default=None, help="Version tag appended to title")
    args = ap.parse_args()

    manifest = yaml.safe_load(args.manifest.read_text(encoding="utf-8"))
    errors = validate(manifest)
    fatal = [e for e in errors if not e.startswith("WARN")]
    for e in errors:
        print(("⚠️  " if e.startswith("WARN") else "❌ ") + e, file=sys.stderr)
    if fatal: sys.exit(1)
    if args.dry_run:
        print("✅ dry-run OK"); return

    deck = manifest["deck"]
    slides = manifest["slides"]
    title = deck["title"] + (f" ({args.tag})" if args.tag else "")
    print(f"📊 Creating: {title}")
    pid = create_presentation(title)
    print(f"   id: {pid}")

    all_reqs = []
    for idx, s in enumerate(slides, 1):
        sid = new_id("sl")
        all_reqs.append(r_create_slide(sid))
        ctx = Ctx(reqs=all_reqs, sid=sid, deck=deck, page_no=idx)
        renderer = RENDERERS.get(s.get("layout"), render_generic)
        for block, x, y, w, h in renderer(s, deck, idx):
            block.emit(ctx, x, y, w, h)

    pres = gws(["slides", "presentations", "get", "--params", json.dumps({"presentationId": pid})])
    default_ids = [sl["objectId"] for sl in pres.get("slides", [])]
    print(f"   sending {len(all_reqs)} requests…")
    batch_update(pid, all_reqs)
    if default_ids:
        batch_update(pid, [{"deleteObject": {"objectId": d}} for d in default_ids])
    print(f"\n✅ https://docs.google.com/presentation/d/{pid}/edit")


if __name__ == "__main__":
    main()
