/**
 * 主页面：Spine 2D 播放器（ArkWeb 渲染 + 模型库 + 播放控制 + 截帧保存）。
 * 状态与持久化全部集中在本页，子组件为受控组件。
 */
import { HdsTabs, HdsTabsController } from '@kit.UIDesignKit';
import { webview } from '@kit.ArkWeb';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { Context } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PrefsManager, PrefsKeys, SlotPrefs } from '../core/PrefsManager';
import { getTheme, ThemeColors } from '../core/Theme';
import {
  BridgeCmdNames,
  BridgeCommand,
  buildRunScript,
  parseModelLoadedEvent,
  parseBridgeErrorEvent,
  parseCaptureChunkEvent,
  parseCaptureFrameEvent,
  parseTransformChangedEvent,
  parseAnimationChangedEvent
} from '../core/BridgeProtocol';
import { SpineModelLibrary } from '../model/SpineModelLibrary';
import { SpineModelItem } from '../model/SpineModelItem';
import { sanitizeAtlas } from '../model/AtlasSanitizer';
import { SpineWebView, SpineBridgeProxy } from '../components/SpineWebView';
import { ModelLibraryPage } from '../components/ModelLibraryPage';
import { SettingsPage } from '../components/SettingsPage';
import { ControlBar } from '../components/ControlBar';
import { BgColorPickerDialog } from '../components/BgColorPickerDialog';
import { GroupPickerDialog } from '../components/GroupPickerDialog';
import { GroupDeleteDialog } from '../components/GroupDeleteDialog';
import { FrameExporter } from '../capture/FrameExporter';

const CAPTURE_TIMEOUT_MS = 15000;
const LOG_DOMAIN = 0x0031;
const TAG = 'SpineIndex';
/** 收藏颜色默认列表（ARGB 十六进制，HdsColorPicker 收藏夹）。 */
const DEFAULT_BG_FAVORITES: Array<string> = [
  '#FF0F172A', '#FF1E293B', '#FF312E81', '#FF0C4A6E',
  '#FF065F46', '#FF10B981', '#FFF59E0B', '#FFEF4444',
  '#FFFFFFFF', '#FF000000'
];

/** 单槽位 UI 状态（不可变更新：修改走 clone + 数组重赋值）。 */
class SlotUiState {
  animations: Array<string> = [];
  skins: Array<string> = [];
  currentAnimation: string = '';
  selectedSkins: Array<string> = [];
  pma: boolean = true;

  clone(): SlotUiState {
    const copy = new SlotUiState();
    copy.animations = this.animations.slice();
    copy.skins = this.skins.slice();
    copy.currentAnimation = this.currentAnimation;
    copy.selectedSkins = this.selectedSkins.slice();
    copy.pma = this.pma;
    return copy;
  }
}

@Entry
@Component
struct Index {
  private webviewController: webview.WebviewController = new webview.WebviewController();
  private tabsController: HdsTabsController = new HdsTabsController();
  private pausedByTabSwitch: boolean = false;
  private bridge: SpineBridgeProxy = new SpineBridgeProxy();
  private webReady: boolean = false;
  private pendingScripts: Array<string> = [];
  private modelsRoot: string = '';
  private bgRoot: string = '';
  private prefs: PrefsManager | null = null;
  private library: SpineModelLibrary | null = null;
  private colorDialogController: CustomDialogController | null = null;
  private groupPickerController: CustomDialogController | null = null;
  private groupDeleteController: CustomDialogController | null = null;

  // 截帧分块缓存
  private captureChunks: Array<string> = [];
  private captureTotal: number = 0;
  private captureTimerId: number = -1;

  @State models: Array<SpineModelItem> = [];
  @State importing: boolean = false;
  @State selectedSlot: number = 0;
  @State playing: boolean = true;
  private pausedByHide: boolean = false;
  @State fps: number = 60;
  @State bgColor: string = '#0F172A';
  /** 背景图文件名（<filesDir>/bg/ 内，空串表示未设置）。 */
  @State bgImageName: string = '';
  @State capturing: boolean = false;
  @State mainModelId: string = '';
  @State subModelId: string = '';
  @State slotUi: Array<SlotUiState> = [new SlotUiState(), new SlotUiState()];
  @State bgFavorites: Array<string> = DEFAULT_BG_FAVORITES.slice();
  @StorageProp('themeDark') themeDark: boolean = true;

  private theme(): ThemeColors {
    return getTheme(this.themeDark);
  }

  /** 切换深浅主题并持久化（theme_mode: dark / light）。 */
  private setThemeDark(dark: boolean): void {
    AppStorage.setOrCreate('themeDark', dark);
    this.prefs?.putString(PrefsKeys.THEME_MODE, dark ? 'dark' : 'light');
    this.prefs?.flush();
  }

  async aboutToAppear(): Promise<void> {
    const context: Context = getContext(this);
    this.modelsRoot = `${context.filesDir}/models`;
    this.bgRoot = `${context.filesDir}/bg`;

    this.bridge.modelLoadedHandler = (json: string): void => {
      this.handleModelLoaded(json);
    };
    this.bridge.errorHandler = (json: string): void => {
      this.handleBridgeError(json);
    };
    this.bridge.captureChunkHandler = (json: string): void => {
      this.handleCaptureChunk(json);
    };
    this.bridge.captureDoneHandler = (json: string): void => {
      this.handleCaptureDone(json);
    };
    this.bridge.transformChangedHandler = (json: string): void => {
      this.handleTransformChanged(json);
    };
    this.bridge.animationChangedHandler = (json: string): void => {
      this.handleAnimationChanged(json);
    };

    this.prefs = await PrefsManager.getInstance(context);
    this.library = SpineModelLibrary.getInstance(context);
    this.models = await this.library.loadModels();

    const prefs = this.prefs;
    this.mainModelId = prefs.getString(PrefsKeys.ACTIVE_MODEL_ID, '');
    this.subModelId = prefs.getString(PrefsKeys.MODEL2_ID, '');
    this.selectedSlot = prefs.getNumber(PrefsKeys.SELECTED_SLOT, 0) === 1 ? 1 : 0;
    this.playing = true;
    this.fps = clampInt(prefs.getNumber(PrefsKeys.TARGET_FPS, 60), 15, 120);
    this.bgColor = intColorToHex(prefs.getNumber(PrefsKeys.BG_COLOR, PrefsManager.defaultBgColor));
    this.bgImageName = prefs.getString(PrefsKeys.BG_IMAGE_PATH, '');
    this.bgFavorites = this.loadBgFavorites(prefs);
    AppStorage.setOrCreate('themeDark', prefs.getString(PrefsKeys.THEME_MODE, 'dark') !== 'light');
    this.initSlotUi(0);
    this.initSlotUi(1);
  }

  aboutToDisappear(): void {
    this.clearCaptureTimer();
  }

  onPageHide(): void {
    if (this.playing) {
      this.pausedByHide = true;
      this.playing = false;
      this.sendCommand({ cmd: BridgeCmdNames.SET_PLAYING, playing: false });
    }
  }

  onPageShow(): void {
    this.resumeAfterOverlay();
  }

  /** 系统选择器/保存器关闭后恢复被 onPageHide 暂停的播放。 */
  private resumeAfterOverlay(): void {
    if (this.pausedByHide) {
      this.pausedByHide = false;
      if (!this.playing) {
        this.playing = true;
        this.sendCommand({ cmd: BridgeCmdNames.SET_PLAYING, playing: true });
      }
    }
  }

  build() {
    HdsTabs({ controller: this.tabsController }) {
      TabContent() {
        Stack({ alignContent: Alignment.Bottom }) {
          SpineWebView({
            controller: this.webviewController,
            bridge: this.bridge,
            modelsRoot: this.modelsRoot,
            bgRoot: this.bgRoot,
            onPageReady: (): void => {
              this.handleWebReady();
            }
          })
          .width('100%')
          .height('100%')

          // 悬浮控制条（避开底部悬浮页签栏）
          Column() {
            ControlBar({
              slot: this.selectedSlot,
              playing: this.playing,
              capturing: this.capturing,
              animations: this.slotUi[this.selectedSlot].animations,
              currentAnimation: this.slotUi[this.selectedSlot].currentAnimation,
              skins: this.slotUi[this.selectedSlot].skins,
              selectedSkins: this.slotUi[this.selectedSlot].selectedSkins,
              onSlotChange: (slot: number): void => {
                this.switchSlot(slot);
              },
              onTogglePlay: (): void => {
                this.togglePlay();
              },
              onAnimationPick: (name: string): void => {
                this.pickAnimation(name);
              },
              onSkinToggle: (name: string): void => {
                this.toggleSkin(name);
              },
              onCapture: (): void => {
                this.startCapture();
              },
              onResetTransform: (): void => {
                this.resetTransform();
              }
            })
            .width('100%')
          }
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 96 })
        }
        .width('100%')
        .height('100%')
      }
      .tabBar({ icon: $r('app.media.tab_play'), text: $r('app.string.tab_play') })

      TabContent() {
        ModelLibraryPage({
          models: this.models,
          mainModelId: this.mainModelId,
          subModelId: this.subModelId,
          importing: this.importing,
          onImport: (): void => {
            this.importModels();
          },
          onSelectMain: (modelId: string): void => {
            this.applyModelSelection(0, modelId);
          },
          onSelectSub: (modelId: string): void => {
            this.applyModelSelection(1, modelId);
          },
          onDelete: (modelId: string): void => {
            this.deleteModelAction(modelId);
          },
          onMoveToGroup: (modelId: string): void => {
            this.moveModelToGroup(modelId);
          },
          onDissolveGroup: (group: string): void => {
            this.dissolveGroupAction(group);
          },
          onDeleteGroup: (group: string): void => {
            this.deleteGroupAction(group);
          }
        })
      }
      .tabBar({ icon: $r('app.media.tab_library'), text: $r('app.string.tab_library') })

      TabContent() {
        SettingsPage({
          pma: this.slotUi[this.selectedSlot].pma,
          fps: this.fps,
          onPmaChange: (pma: boolean): void => {
            this.togglePma(pma);
          },
          onFpsChange: (fps: number): void => {
            this.changeFps(fps);
          },
          onToggleTheme: (dark: boolean): void => {
            this.setThemeDark(dark);
          },
          onOpenBgSettings: (): void => {
            this.openColorDialog();
          }
        })
      }
      .tabBar({ icon: $r('app.media.tab_settings'), text: $r('app.string.tab_settings') })
    }
    .barOverlap(true)
    .barPosition(BarPosition.End)
    .vertical(false)
    .scrollable(false)
    .cachedMaxCount(2, TabsCacheMode.CACHE_BOTH_SIDE)
    .barFloatingStyle()
    .onChange((index: number) => {
      this.handleTabChange(index);
    })
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme().pageBg)
  }

  /** 切离播放页暂停渲染，切回恢复（同 onPageHide/resumeAfterOverlay 模式）。 */
  private handleTabChange(index: number): void {
    if (index === 0) {
      if (this.pausedByTabSwitch) {
        this.pausedByTabSwitch = false;
        this.playing = true;
        this.sendCommand({ cmd: BridgeCmdNames.SET_PLAYING, playing: true });
      }
    } else {
      if (this.playing) {
        this.pausedByTabSwitch = true;
        this.playing = false;
        this.sendCommand({ cmd: BridgeCmdNames.SET_PLAYING, playing: false });
      }
    }
  }

  // ==================== Web 就绪与命令发送 ====================

  private handleWebReady(): void {
    if (this.webReady) {
      return;
    }
    this.webReady = true;
    hilog.info(LOG_DOMAIN, TAG, 'web ready, main=%{public}s sub=%{public}s', this.mainModelId, this.subModelId);
    this.sendCommand({ cmd: BridgeCmdNames.SET_GESTURE_SLOT, slot: this.selectedSlot });
    this.sendCommand({ cmd: BridgeCmdNames.SET_FPS, fps: this.fps });
    this.sendCommand({ cmd: BridgeCmdNames.SET_BG_COLOR, color: this.bgColor });
    if (this.bgImageName.length > 0) {
      this.sendCommand({ cmd: BridgeCmdNames.SET_BG_IMAGE, url: `/bg/${this.bgImageName}` });
    }
    this.sendCommand({ cmd: BridgeCmdNames.SET_PLAYING, playing: this.playing });
    this.loadSlotModel(0);
    this.loadSlotModel(1);
    const queued = this.pendingScripts;
    this.pendingScripts = [];
    for (const script of queued) {
      this.runScript(script);
    }
  }

  private sendCommand(command: BridgeCommand): void {
    const script = buildRunScript(command);
    if (!this.webReady) {
      this.pendingScripts.push(script);
      return;
    }
    this.runScript(script);
  }

  private runScript(script: string): void {
    this.webviewController.runJavaScript(script).catch((err: BusinessError): void => {
      console.error(`runJavaScript failed: ${err.message}`);
    });
  }

  /** 按当前状态加载指定槽位模型（含图集修复/动画/皮肤/变换/PMA 期望值下发）。 */
  private async loadSlotModel(slot: number): Promise<void> {
    const prefs = this.prefs;
    const library = this.library;
    if (prefs === null || library === null) {
      return;
    }
    const modelId = slot === 0 ? this.mainModelId : this.subModelId;
    if (modelId.length === 0) {
      this.sendCommand({ cmd: BridgeCmdNames.CLEAR_SLOT, slot: slot });
      return;
    }
    const model = library.getModelById(modelId);
    if (model === null) {
      this.sendCommand({ cmd: BridgeCmdNames.CLEAR_SLOT, slot: slot });
      return;
    }
    // 图集清理与尺寸校正（对齐 Android 加载时 sanitize + 缓存）
    let atlasFile = model.atlasFile;
    if (atlasFile.length > 0) {
      const sanitized = await sanitizeAtlas(model.atlasPath());
      atlasFile = sanitized.atlasFile;
      hilog.info(LOG_DOMAIN, TAG, 'atlas sanitized slot=%{public}d file=%{public}s fromCache=%{public}s',
        slot, sanitized.atlasFile, String(sanitized.fromCache));
    }
    // sanitize 为异步操作，期间模型选择可能已变化：过期加载直接丢弃
    const currentId = slot === 0 ? this.mainModelId : this.subModelId;
    if (currentId !== modelId) {
      return;
    }
    // config.json 接线（对齐 Android）：scale 作为 Spine 加载器缩放传入 Web 侧
    const config = library.readModelConfig(model);
    if (config !== null) {
      hilog.info(LOG_DOMAIN, TAG, 'config.json slot=%{public}d scale=%{public}s idle_motion=%{public}s',
        slot, String(config.scale), config.idle_motion);
    }
    const ui = this.slotUi[slot];
    this.sendCommand({
      cmd: BridgeCmdNames.LOAD_MODEL,
      slot: slot,
      modelId: model.id,
      skelFile: model.skelFile,
      atlasFile: atlasFile,
      version: model.version,
      pma: ui.pma,
      configScale: config !== null ? config.scale : 1,
      idleMotion: config !== null ? config.idle_motion : ''
    });
    if (ui.currentAnimation.length > 0) {
      this.sendCommand({ cmd: BridgeCmdNames.PLAY_ANIMATION, slot: slot, name: ui.currentAnimation, loop: true });
    }
    this.sendCommand({ cmd: BridgeCmdNames.SET_SKINS, slot: slot, skins: ui.selectedSkins });
    this.sendCommand({
      cmd: BridgeCmdNames.SET_TRANSFORM,
      slot: slot,
      scale: prefs.getNumber(SlotPrefs.scaleKey(slot), 1),
      x: prefs.getNumber(SlotPrefs.posXKey(slot), 0),
      y: prefs.getNumber(SlotPrefs.posYKey(slot), 0)
    });
    this.sendCommand({ cmd: BridgeCmdNames.SET_PMA, slot: slot, pma: ui.pma });
  }

  /** 用偏好与模型元数据初始化槽位 UI 状态。 */
  private initSlotUi(slot: number): void {
    const prefs = this.prefs;
    const library = this.library;
    if (prefs === null || library === null) {
      return;
    }
    const modelId = slot === 0 ? this.mainModelId : this.subModelId;
    const model = modelId.length > 0 ? library.getModelById(modelId) : null;
    const animations = model !== null ? model.animations : [];
    const skins = model !== null ? model.skins : [];
    const savedAnim = prefs.getString(SlotPrefs.animationKey(slot), '');
    const config = model !== null ? library.readModelConfig(model) : null;
    const idleMotion = config !== null ? config.idle_motion : '';
    // 动作链（对齐 Android）：上层期望（偏好）> config.idle_motion > 第一个动作。
    // 二进制（SKEL）模型导入时 animations 是占位 ['idle']，不能用于链解析：
    // 留空交给 Web 侧用真实动画名解析（desired > idle_motion > first）并回报同步。
    const metaTrusted = model !== null &&
      (model.format === 'JSON' || !(animations.length === 1 && animations[0] === 'idle'));
    let currentAnimation = '';
    if (savedAnim.length > 0 && metaTrusted && animations.includes(savedAnim)) {
      currentAnimation = savedAnim;
    } else if (idleMotion.length > 0 && metaTrusted && animations.includes(idleMotion)) {
      currentAnimation = idleMotion;
    } else if (metaTrusted && animations.length > 0) {
      currentAnimation = animations[0];
    }
    const selectedSkins = prefs.getSelectedSkins(SlotPrefs.skinsJsonKey(slot), '');
    const effectiveSkins = selectedSkins.length > 0 ? selectedSkins : (skins.length > 0 ? [skins[0]] : []);
    const pma = prefs.getBool(SlotPrefs.pmaKey(slot), true);
    this.updateSlotUi(slot, (state: SlotUiState): void => {
      state.animations = animations;
      state.skins = skins;
      state.currentAnimation = currentAnimation;
      state.selectedSkins = effectiveSkins;
      state.pma = pma;
    });
  }

  /** 不可变更新槽位 UI 状态（clone + 数组重赋值，保证 @State 刷新）。 */
  private updateSlotUi(slot: number, mutate: (state: SlotUiState) => void): void {
    const copy = this.slotUi[slot].clone();
    mutate(copy);
    const newArray = [this.slotUi[0], this.slotUi[1]];
    newArray[slot] = copy;
    this.slotUi = newArray;
  }

  // ==================== Web 事件处理 ====================

  private handleModelLoaded(json: string): void {
    const event = parseModelLoadedEvent(json);
    if (event === null) {
      hilog.warn(LOG_DOMAIN, TAG, 'modelLoaded event parse failed: %{public}s', json);
      return;
    }
    hilog.info(LOG_DOMAIN, TAG, 'model loaded slot=%{public}d id=%{public}s anims=%{public}d skins=%{public}d',
      event.slot, event.modelId, event.animations.length, event.skins.length);
    if (this.library !== null) {
      this.library.updateModelAnimSkins(event.modelId, event.animations, event.skins);
      this.models = this.library.getModels();
    }
    this.updateSlotUi(event.slot, (state: SlotUiState): void => {
      state.animations = event.animations;
      state.skins = event.skins;
      // 空值留给 Web 侧兜底链（idle_motion/first）经 onAnimationChanged 回报同步；
      // 仅校正非空但已不存在的期望动作
      if (state.currentAnimation.length > 0 && !event.animations.includes(state.currentAnimation) &&
        event.animations.length > 0) {
        state.currentAnimation = event.animations[0];
      }
      const kept = state.selectedSkins.filter((name: string): boolean => event.skins.includes(name));
      state.selectedSkins = kept.length > 0 ? kept : (event.skins.length > 0 ? [event.skins[0]] : []);
    });
    const ui = this.slotUi[event.slot];
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putString(SlotPrefs.animationKey(event.slot), ui.currentAnimation);
      prefs.putSelectedSkins(SlotPrefs.skinsJsonKey(event.slot), ui.selectedSkins);
      prefs.flush();
    }
    // 加载后校正动画与皮肤（偏好中的名称可能已不存在）
    this.sendCommand({ cmd: BridgeCmdNames.PLAY_ANIMATION, slot: event.slot, name: ui.currentAnimation, loop: true });
    this.sendCommand({ cmd: BridgeCmdNames.SET_SKINS, slot: event.slot, skins: ui.selectedSkins });
  }

  private handleBridgeError(json: string): void {
    const event = parseBridgeErrorEvent(json);
    if (event === null) {
      return;
    }
    hilog.error(LOG_DOMAIN, TAG, 'bridge error slot=%{public}d code=%{public}s message=%{public}s',
      event.slot, event.code, event.message);
    if (event.code === 'CAPTURE_ERROR') {
      this.capturing = false;
      this.clearCaptureTimer();
    }
    this.getUIContext().getPromptAction().showToast({ message: event.message, duration: 2500 });
  }

  private handleTransformChanged(json: string): void {
    const event = parseTransformChangedEvent(json);
    if (event === null) {
      return;
    }
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putNumber(SlotPrefs.scaleKey(event.slot), event.scale);
      prefs.putNumber(SlotPrefs.posXKey(event.slot), event.x);
      prefs.putNumber(SlotPrefs.posYKey(event.slot), event.y);
      prefs.flush();
    }
  }

  private handleAnimationChanged(json: string): void {
    const event = parseAnimationChangedEvent(json);
    if (event === null) {
      return;
    }
    this.updateSlotUi(event.slot, (state: SlotUiState): void => {
      state.currentAnimation = event.name;
    });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putString(SlotPrefs.animationKey(event.slot), event.name);
      prefs.flush();
    }
  }

  private handleCaptureChunk(json: string): void {
    const event = parseCaptureChunkEvent(json);
    if (event === null) {
      return;
    }
    if (event.index === 0) {
      this.captureChunks = [];
      this.captureTotal = event.total;
    }
    if (event.total !== this.captureTotal || event.index !== this.captureChunks.length) {
      return;
    }
    this.captureChunks.push(event.data);
  }

  private handleCaptureDone(json: string): void {
    const event = parseCaptureFrameEvent(json);
    if (event === null || !event.done) {
      return;
    }
    this.clearCaptureTimer();
    if (this.captureTotal === 0 || this.captureChunks.length !== this.captureTotal) {
      this.capturing = false;
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_capture_fail') });
      return;
    }
    const base64 = this.captureChunks.join('');
    this.captureChunks = [];
    this.captureTotal = 0;
    FrameExporter.savePng(getContext(this), base64)
      .then((uri: string): void => {
        this.capturing = false;
        this.resumeAfterOverlay();
        if (uri.length === 0) {
          this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_capture_cancel') });
        } else {
          this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_capture_ok') });
        }
      })
      .catch((err: BusinessError): void => {
        this.capturing = false;
        this.resumeAfterOverlay();
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_capture_fail') });
      });
  }

  // ==================== 用户操作 ====================

  private async importModels(): Promise<void> {
    if (this.importing) {
      return;
    }
    const docPicker = new picker.DocumentViewPicker(getContext(this));
    const options = new picker.DocumentSelectOptions();
    options.fileSuffixFilters = ['.zip'];
    options.maxSelectNumber = 1;
    let uris: Array<string> = [];
    try {
      uris = await docPicker.select(options);
    } catch (err) {
      this.resumeAfterOverlay();
      return;
    }
    this.resumeAfterOverlay();
    if (uris.length === 0) {
      return;
    }
    this.pickImportGroup(uris[0]);
  }

  /** 导入前选择分组（记忆上次选择），确定后执行导入。 */
  private pickImportGroup(zipUri: string): void {
    const library = this.library;
    const prefs = this.prefs;
    if (library === null || prefs === null) {
      return;
    }
    this.groupPickerController = new CustomDialogController({
      builder: GroupPickerDialog({
        groups: library.getGroupNames(),
        initialGroup: prefs.getString(PrefsKeys.LAST_IMPORT_GROUP, ''),
        confirm: (group: string): void => {
          prefs.putString(PrefsKeys.LAST_IMPORT_GROUP, group);
          prefs.flush();
          this.runImport(zipUri, group);
        }
      }),
      autoCancel: true
    });
    this.groupPickerController.open();
  }

  private async runImport(zipUri: string, group: string): Promise<void> {
    const library = this.library;
    if (library === null) {
      return;
    }
    this.importing = true;
    try {
      const imported = await library.importZip(zipUri, group);
      this.models = library.getModels();
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_import_ok') });
      if (this.mainModelId.length === 0 && imported.length > 0) {
        this.applyModelSelection(0, imported[0].id);
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : '';
      this.getUIContext().getPromptAction().showToast({
        message: message.length > 0 ? message : $r('app.string.toast_import_fail')
      });
    } finally {
      this.importing = false;
    }
  }

  /** 选择模型到指定槽位（4.1 运行时门禁 + 偏好持久化 + 下发加载）。 */
  private applyModelSelection(slot: number, modelId: string): void {
    const library = this.library;
    const prefs = this.prefs;
    if (library === null || prefs === null) {
      return;
    }
    const model = library.getModelById(modelId);
    if (model === null) {
      return;
    }
    if (!model.isSupported()) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_unsupported') });
      return;
    }
    if (slot === 0) {
      this.mainModelId = modelId;
      prefs.putString(PrefsKeys.ACTIVE_MODEL_ID, modelId);
    } else {
      this.subModelId = modelId;
      prefs.putString(PrefsKeys.MODEL2_ID, modelId);
    }
    prefs.flush();
    this.initSlotUi(slot);
    this.loadSlotModel(slot);
  }

  private deleteModelAction(modelId: string): void {
    const library = this.library;
    if (library === null) {
      return;
    }
    this.getUIContext().showAlertDialog({
      message: $r('app.string.confirm_delete'),
      primaryButton: {
        value: $r('app.string.dialog_cancel'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: $r('app.string.dialog_delete'),
        fontColor: this.theme().danger,
        action: (): void => {
          this.performDelete(modelId);
        }
      }
    });
  }

  private performDelete(modelId: string): void {
    const library = this.library;
    if (library === null) {
      return;
    }
    library.deleteModel(modelId)
      .then((): void => {
        this.models = library.getModels();
        this.cleanupSlotsForDeleted(modelId);
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_deleted') });
      })
      .catch((err: BusinessError): void => {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_delete_fail') });
      });
  }

  /** 模型被删除后清理其占用的槽位（偏好 + WebView 槽 + 面板 UI）。 */
  private cleanupSlotsForDeleted(modelId: string): void {
    const prefs = this.prefs;
    if (prefs === null) {
      return;
    }
    if (this.mainModelId === modelId) {
      this.mainModelId = '';
      prefs.putString(PrefsKeys.ACTIVE_MODEL_ID, '');
      this.sendCommand({ cmd: BridgeCmdNames.CLEAR_SLOT, slot: 0 });
      this.resetSlotUi(0);
    }
    if (this.subModelId === modelId) {
      this.subModelId = '';
      prefs.putString(PrefsKeys.MODEL2_ID, '');
      this.sendCommand({ cmd: BridgeCmdNames.CLEAR_SLOT, slot: 1 });
      this.resetSlotUi(1);
    }
    prefs.flush();
  }

  // ==================== 分组操作 ====================

  /** 单卡「移动到分组」：打开分组选择弹窗。 */
  private moveModelToGroup(modelId: string): void {
    const library = this.library;
    if (library === null) {
      return;
    }
    const model = library.getModelById(modelId);
    if (model === null) {
      return;
    }
    this.groupPickerController = new CustomDialogController({
      builder: GroupPickerDialog({
        groups: library.getGroupNames(),
        initialGroup: model.group,
        confirm: (group: string): void => {
          library.setModelGroup(modelId, group)
            .then((): void => {
              this.models = library.getModels();
            })
            .catch((): void => {
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_group_update_fail') });
            });
        }
      }),
      autoCancel: true
    });
    this.groupPickerController.open();
  }

  /** 解散分组（组内模型保留，移入未分组），二次确认。 */
  private dissolveGroupAction(group: string): void {
    const library = this.library;
    if (library === null || group.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      message: $r('app.string.confirm_dissolve_group', group),
      primaryButton: {
        value: $r('app.string.dialog_cancel'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: $r('app.string.dialog_ok'),
        action: (): void => {
          library.dissolveGroup(group)
            .then((): void => {
              this.models = library.getModels();
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_group_dissolved') });
            });
        }
      }
    });
  }

  /** 删除分组：弹三选一确认（仅删分组 / 删除组及全部模型 / 取消）。 */
  private deleteGroupAction(group: string): void {
    const library = this.library;
    if (library === null || group.length === 0) {
      return;
    }
    this.groupDeleteController = new CustomDialogController({
      builder: GroupDeleteDialog({
        groupName: group,
        confirm: (deleteModels: boolean): void => {
          library.deleteGroup(group, deleteModels)
            .then((deletedIds: Array<string>): void => {
              this.models = library.getModels();
              for (const id of deletedIds) {
                this.cleanupSlotsForDeleted(id);
              }
              this.getUIContext().getPromptAction().showToast({
                message: deleteModels ? $r('app.string.toast_deleted') : $r('app.string.toast_group_dissolved')
              });
            })
            .catch((err: BusinessError): void => {
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_delete_fail') });
            });
        }
      }),
      autoCancel: true
    });
    this.groupDeleteController.open();
  }

  private resetSlotUi(slot: number): void {
    this.updateSlotUi(slot, (state: SlotUiState): void => {
      state.animations = [];
      state.skins = [];
      state.currentAnimation = '';
      state.selectedSkins = [];
    });
  }

  private switchSlot(slot: number): void {
    if (slot === this.selectedSlot) {
      return;
    }
    this.selectedSlot = slot;
    this.sendCommand({ cmd: BridgeCmdNames.SET_GESTURE_SLOT, slot: slot });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putNumber(PrefsKeys.SELECTED_SLOT, slot);
      prefs.flush();
    }
  }

  private togglePlay(): void {
    this.playing = !this.playing;
    this.sendCommand({ cmd: BridgeCmdNames.SET_PLAYING, playing: this.playing });
  }

  private pickAnimation(name: string): void {
    const slot = this.selectedSlot;
    this.updateSlotUi(slot, (state: SlotUiState): void => {
      state.currentAnimation = name;
    });
    this.sendCommand({ cmd: BridgeCmdNames.PLAY_ANIMATION, slot: slot, name: name, loop: true });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putString(SlotPrefs.animationKey(slot), name);
      prefs.flush();
    }
  }

  private toggleSkin(name: string): void {
    const slot = this.selectedSlot;
    this.updateSlotUi(slot, (state: SlotUiState): void => {
      if (state.selectedSkins.includes(name)) {
        state.selectedSkins = state.selectedSkins.filter((item: string): boolean => item !== name);
      } else {
        const next = state.selectedSkins.slice();
        next.push(name);
        state.selectedSkins = next;
      }
    });
    const ui = this.slotUi[slot];
    this.sendCommand({ cmd: BridgeCmdNames.SET_SKINS, slot: slot, skins: ui.selectedSkins });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putSelectedSkins(SlotPrefs.skinsJsonKey(slot), ui.selectedSkins);
      prefs.flush();
    }
  }

  private togglePma(pma: boolean): void {
    const slot = this.selectedSlot;
    this.updateSlotUi(slot, (state: SlotUiState): void => {
      state.pma = pma;
    });
    this.sendCommand({ cmd: BridgeCmdNames.SET_PMA, slot: slot, pma: pma });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putBool(SlotPrefs.pmaKey(slot), pma);
      prefs.flush();
    }
  }

  private changeFps(fps: number): void {
    const value = clampInt(fps, 15, 120);
    if (value === this.fps) {
      return;
    }
    this.fps = value;
    this.sendCommand({ cmd: BridgeCmdNames.SET_FPS, fps: value });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putNumber(PrefsKeys.TARGET_FPS, value);
      prefs.flush();
    }
  }

  private resetTransform(): void {
    const slot = this.selectedSlot;
    this.sendCommand({ cmd: BridgeCmdNames.SET_TRANSFORM, slot: slot, scale: 1, x: 0, y: 0 });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putNumber(SlotPrefs.scaleKey(slot), 1);
      prefs.putNumber(SlotPrefs.posXKey(slot), 0);
      prefs.putNumber(SlotPrefs.posYKey(slot), 0);
      prefs.flush();
    }
    this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_transform_reset') });
  }

  private openColorDialog(): void {
    this.colorDialogController = new CustomDialogController({
      builder: BgColorPickerDialog({
        pickedColor: this.bgColor,
        hasBgImage: this.bgImageName.length > 0,
        initialFavorites: this.bgFavorites.slice(),
        confirm: (color: string): void => {
          this.applyBgColor(color);
        },
        favoritesUpdate: (favorites: Array<string>): void => {
          this.saveBgFavorites(favorites);
        },
        pickImage: (): void => {
          this.pickBackgroundImage();
        },
        removeImage: (): void => {
          this.removeBackgroundImage();
        }
      }),
      autoCancel: true
    });
    this.colorDialogController.open();
  }

  private loadBgFavorites(prefs: PrefsManager): Array<string> {
    const raw = prefs.getString(PrefsKeys.BG_FAVORITES, '');
    if (raw.length === 0) {
      return DEFAULT_BG_FAVORITES.slice();
    }
    try {
      const parsed = JSON.parse(raw) as Array<string>;
      const result = new Array<string>();
      for (const item of parsed) {
        if (typeof item === 'string' && item.length > 0) {
          result.push(item);
        }
      }
      return result.length > 0 ? result : DEFAULT_BG_FAVORITES.slice();
    } catch (err) {
      return DEFAULT_BG_FAVORITES.slice();
    }
  }

  private saveBgFavorites(favorites: Array<string>): void {
    this.bgFavorites = favorites.slice();
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putString(PrefsKeys.BG_FAVORITES, JSON.stringify(favorites));
      prefs.flush();
    }
  }

  /** 选取自定义背景图：PhotoViewPicker → 拷贝到 <filesDir>/bg/ → 持久化 + 下发。 */
  private async pickBackgroundImage(): Promise<void> {
    const photoPicker = new picker.PhotoViewPicker();
    const options = new picker.PhotoSelectOptions();
    options.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = 1;
    let uris: Array<string> = [];
    try {
      const result: picker.PhotoSelectResult = await photoPicker.select(options);
      uris = result.photoUris;
    } catch (err) {
      this.resumeAfterOverlay();
      return;
    }
    this.resumeAfterOverlay();
    if (uris.length === 0) {
      return;
    }
    const prefs = this.prefs;
    if (prefs === null) {
      return;
    }
    const uri = uris[0];
    const lower = uri.toLowerCase();
    let ext = '.png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      ext = '.jpg';
    } else if (lower.endsWith('.webp')) {
      ext = '.webp';
    } else if (lower.endsWith('.gif')) {
      ext = '.gif';
    }
    const fileName = `custom_bg_${Date.now()}${ext}`;
    let srcFile: fileIo.File | null = null;
    try {
      if (!fileIo.accessSync(this.bgRoot, fileIo.AccessModeType.EXIST)) {
        fileIo.mkdirSync(this.bgRoot, true);
      }
      srcFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      await fileIo.copyFile(srcFile.fd, `${this.bgRoot}/${fileName}`);
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_bg_load_fail') });
      return;
    } finally {
      if (srcFile !== null) {
        try {
          fileIo.closeSync(srcFile);
        } catch (err) {
          // 忽略关闭失败
        }
      }
    }
    // 替换：清理旧背景图文件，避免残留
    this.deleteBgFile(this.bgImageName);
    this.bgImageName = fileName;
    prefs.putString(PrefsKeys.BG_IMAGE_PATH, fileName);
    prefs.flush();
    this.sendCommand({ cmd: BridgeCmdNames.SET_BG_IMAGE, url: `/bg/${fileName}` });
  }

  /** 移除自定义背景图：删文件 + 清偏好 + 通知 Web 回纯色。 */
  private removeBackgroundImage(): void {
    const prefs = this.prefs;
    this.deleteBgFile(this.bgImageName);
    this.bgImageName = '';
    if (prefs !== null) {
      prefs.putString(PrefsKeys.BG_IMAGE_PATH, '');
      prefs.flush();
    }
    this.sendCommand({ cmd: BridgeCmdNames.SET_BG_IMAGE, url: '' });
  }

  private deleteBgFile(fileName: string): void {
    if (fileName.length === 0) {
      return;
    }
    try {
      const path = `${this.bgRoot}/${fileName}`;
      if (fileIo.accessSync(path, fileIo.AccessModeType.EXIST)) {
        fileIo.unlinkSync(path);
      }
    } catch (err) {
      // 清理失败不阻断流程
    }
  }

  private applyBgColor(color: string): void {
    const rgbHex = normalizeRgbHex(color);
    this.bgColor = rgbHex;
    this.sendCommand({ cmd: BridgeCmdNames.SET_BG_COLOR, color: rgbHex });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putNumber(PrefsKeys.BG_COLOR, hexToIntColor(rgbHex));
      prefs.flush();
    }
  }

  private startCapture(): void {
    if (this.capturing || !this.webReady) {
      return;
    }
    this.capturing = true;
    this.captureChunks = [];
    this.captureTotal = 0;
    this.sendCommand({ cmd: BridgeCmdNames.CAPTURE_FRAME });
    this.captureTimerId = setTimeout((): void => {
      if (this.capturing) {
        this.capturing = false;
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_capture_fail') });
      }
    }, CAPTURE_TIMEOUT_MS);
  }

  private clearCaptureTimer(): void {
    if (this.captureTimerId >= 0) {
      clearTimeout(this.captureTimerId);
      this.captureTimerId = -1;
    }
  }
}

// ==================== 颜色与数值工具（模块级具名函数） ====================

/** 0xAARRGGBB 整型色值 → '#RRGGBB' 显示串。 */
function intColorToHex(color: number): string {
  const rgb = color & 0xFFFFFF;
  const r = (rgb >> 16) & 0xFF;
  const g = (rgb >> 8) & 0xFF;
  const b = rgb & 0xFF;
  return `#${toHex2(r)}${toHex2(g)}${toHex2(b)}`;
}

function toHex2(value: number): string {
  const hex = value.toString(16).toUpperCase();
  return hex.length === 1 ? `0${hex}` : hex;
}

/** '#RRGGBB' → 0xAARRGGBB 整型色值（非法回退默认背景色）。 */
function hexToIntColor(hex: string): number {
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
function normalizeRgbHex(hex: string): string {
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
function clampInt(value: number, min: number, max: number): number {
  const v = Math.round(value);
  return Math.min(max, Math.max(min, v));
}
