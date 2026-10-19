/**
 * 深浅主题调色板（对齐安卓 UiPalette）：getTheme(dark) 返回整套颜色 token，
 * 各组件经 @StorageProp('themeDark') 感知主题并取色。
 */
export interface ThemeColors {
  pageBg: number;
  drawerBg: number;
  bottomBarBg: number;
  card: number;
  cardActive: number;
  cardSelected: number;
  chip: number;
  divider: number;
  text: number;
  textSecondary: number;
  textMuted: number;
  accent: number;
  accentSoft: number;
  border: number;
  importBtn: number;
  dialogBg: number;
  scrim: number;
  danger: number;
  badgeBg: number;
  badgeText: number;
  badgeWarnBg: number;
  badgeWarnText: number;
}

const DARK_THEME: ThemeColors = {
  pageBg: 0xFF0F172A,
  drawerBg: 0x990F172A,
  bottomBarBg: 0x4D1E293B,
  card: 0xFF1E293B,
  cardActive: 0xFF312E81,
  cardSelected: 0xFF4338CA,
  chip: 0xB3334155,
  divider: 0xFF334155,
  text: 0xFFFFFFFF,
  textSecondary: 0xFFCBD5E1,
  textMuted: 0xFF808080,
  accent: 0xFF6366F1,
  accentSoft: 0xFF818CF8,
  border: 0xFF475569,
  importBtn: 0xFF4F46E5,
  dialogBg: 0xFF0F172A,
  scrim: 0x59000000,
  danger: 0xFFEF4444,
  badgeBg: 0x336366F1,
  badgeText: 0xFFA5B4FC,
  badgeWarnBg: 0x33F59E0B,
  badgeWarnText: 0xFFFBBF24
};

const LIGHT_THEME: ThemeColors = {
  pageBg: 0xFFF8FAFC,
  drawerBg: 0x99FFFFFF,
  bottomBarBg: 0x4DF1F5F9,
  card: 0xFFF1F5F9,
  cardActive: 0xFFE0E7FF,
  cardSelected: 0xFF6366F1,
  chip: 0xB3CBD5E1,
  divider: 0xFFCBD5E1,
  text: 0xFF1E293B,
  textSecondary: 0xFF475569,
  textMuted: 0xFF64748B,
  accent: 0xFF4F46E5,
  accentSoft: 0xFF4338CA,
  border: 0xFFCBD5E1,
  importBtn: 0xFF4F46E5,
  dialogBg: 0xFFFFFFFF,
  scrim: 0x40000000,
  danger: 0xFFDC2626,
  badgeBg: 0x1A4F46E5,
  badgeText: 0xFF4F46E5,
  badgeWarnBg: 0x33F59E0B,
  badgeWarnText: 0xFFB45309
};

export function getTheme(dark: boolean): ThemeColors {
  return dark ? DARK_THEME : LIGHT_THEME;
}
