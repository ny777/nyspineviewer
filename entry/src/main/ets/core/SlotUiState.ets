/**
 * 单槽位 UI 状态（不可变更新：修改走 clone + 数组重赋值）。
 * 自 Index.ets 抽出，供主页面与各协调器共用。
 */
export class SlotUiState {
  animations: Array<string> = [];
  skins: Array<string> = [];
  currentAnimation: string = '';
  selectedSkins: Array<string> = [];
  pma: boolean = true;
  mirrored: boolean = false;
  alpha: number = 100;
  /** 播放速度 0.25-2（1 = 原速）。 */
  speed: number = 1;
  /** 循环轮播列表（按点选顺序）。 */
  playlist: Array<string> = [];
  playlistEnabled: boolean = false;

  clone(): SlotUiState {
    const copy = new SlotUiState();
    copy.animations = this.animations.slice();
    copy.skins = this.skins.slice();
    copy.currentAnimation = this.currentAnimation;
    copy.selectedSkins = this.selectedSkins.slice();
    copy.pma = this.pma;
    copy.mirrored = this.mirrored;
    copy.alpha = this.alpha;
    copy.speed = this.speed;
    copy.playlist = this.playlist.slice();
    copy.playlistEnabled = this.playlistEnabled;
    return copy;
  }
}
