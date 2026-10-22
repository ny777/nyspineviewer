/**
 * 颜色与数值工具（模块级具名函数，自 Index.ets 抽出）。
 */
import { PrefsManager } from './PrefsManager';

/** 0xAARRGGBB 整型色值 → '#RRGGBB' 显示串。 */
export function intColorToHex(color: number): string {
  const rgb = color & 0xFFFFFF;
  const r = (rgb >> 16) & 0xFF;
  const g = (rgb >> 8) & 0xFF;
  const b = rgb & 0xFF;
  return `#${toHex2(r)}${toHex2(g)}${toHex2(b)}`;
}

/** 数值 → 2 位大写十六进制串。 */
export function toHex2(value: number): string {
  const hex = value.toString(16).toUpperCase();
  return hex.length === 1 ? `0${hex}` : hex;
}

/** '#RRGGBB' → 0xAARRGGBB 整型色值（非法回退默认背景色）。 */
export function hexToIntColor(hex: string): number {
  const clean = hex.startsWith('#') ? hex.substring(1) : hex;
  const rgbText = clean.length === 8 ? clean.substring(2) : clean;
  if (rgbText.length !== 6) {
    return PrefsManager.defaultBgColor;
  }
  const rgb = parseInt(rgbText, 16);
  if (Number.isNaN(rgb)) {
    return PrefsManager.defaultBgColor;
  }
  return 0xFF000000 | rgb;
}

/** 归一化为 '#RRGGBB'（兼容 8 位 ARGB 输入，如 HdsColorPicker 回调值）。 */
export function normalizeRgbHex(hex: string): string {
  const clean = hex.startsWith('#') ? hex.substring(1) : hex;
  const rgbText = clean.length === 8 ? clean.substring(2) : clean;
  if (rgbText.length !== 6) {
    return '#0F172A';
  }
  const rgb = parseInt(rgbText, 16);
  if (Number.isNaN(rgb)) {
    return '#0F172A';
  }
  const r = (rgb >> 16) & 0xFF;
  const g = (rgb >> 8) & 0xFF;
  const b = rgb & 0xFF;
  return `#${toHex2(r)}${toHex2(g)}${toHex2(b)}`;
}

/** 数值夹取并取整。 */
export function clampInt(value: number, min: number, max: number): number {
  const v = Math.round(value);
  return Math.min(max, Math.max(min, v));
}

/** 浮点夹取并归一到两位小数（速度/过渡用）。 */
export function clampFloat2(value: number, min: number, max: number): number {
  const v = Math.round(value * 100) / 100;
  return Math.min(max, Math.max(min, v));
}
