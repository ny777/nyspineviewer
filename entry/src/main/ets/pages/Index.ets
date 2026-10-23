/**
 * 主页面：Spine 2D 播放器（ArkWeb 渲染 + 模型库 + 播放控制 + 截帧保存）。
 * 状态与持久化全部集中在本页，子组件为受控组件。
 */
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { Context } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PrefsManager, PrefsKeys, SlotPrefs, PlaylistPrefs } from '../core/PrefsManager';
import { getTheme, ThemeColors } from '../core/Theme';
import {
  BridgeCmdNames,
  BridgeCommand,
  TapMotionEntry,
  buildRunScript,
  parseModelLoadedEvent,
  parseBridgeErrorEvent,
  parseTransformChangedEvent,
  parseAnimationChangedEvent
} from '../core/BridgeProtocol';
import { intColorToHex, hexToIntColor, normalizeRgbHex, clampInt, clampFloat2 } from '../core/ColorUtils';
import { SlotUiState } from '../core/SlotUiState';
import { SpineModelLibrary, BatchImportResult, TrashEntry } from '../model/SpineModelLibrary';
import { SpineModelItem } from '../model/SpineModelItem';
import { sanitizeAtlas } from '../model/AtlasSanitizer';
import { SpineWebView, SpineBridgeProxy } from '../components/SpineWebView';
import { ModelLibraryPage } from '../components/ModelLibraryPage';
import { SettingsPage } from '../components/SettingsPage';
import { ControlBar } from '../components/ControlBar';
import { BgColorPickerDialog } from '../components/BgColorPickerDialog';
import { GroupPickerDialog } from '../components/GroupPickerDialog';
import { GroupDeleteDialog } from '../components/GroupDeleteDialog';
import { RenameGroupDialog } from '../components/RenameGroupDialog';
import { RenameModelDialog } from '../components/RenameModelDialog';
import { TrashDialog } from '../components/TrashDialog';
import { FrameExporter } from '../capture/FrameExporter';
import { ThumbStore } from '../capture/ThumbStore';
import { CaptureCoordinator, CaptureDeps, CAPTURE_PURPOSE_GALLERY, CAPTURE_PURPOSE_WIDGET, CAPTURE_PURPOSE_WIDGET_MANUAL, CAPTURE_PURPOSE_THUMB } from '../capture/CaptureCoordinator';
import { ThumbPipeline, ThumbDeps } from '../capture/ThumbPipeline';
import { WidgetCoordinator, WidgetDeps } from '../widget/WidgetCoordinator';
import { TrashCoordinator, TrashDeps } from '../model/TrashCoordinator';

const LOG_DOMAIN = 0x0031;
const TAG = 'SpineIndex';
/** 收藏颜色默认列表（ARGB 十六进制，HdsColorPicker 收藏夹）。 */
const DEFAULT_BG_FAVORITES: Array<string> = [
  '#FF0F172A', '#FF1E293B', '#FF312E81', '#FF0C4A6E',
  '#FF065F46', '#FF10B981', '#FFF59E0B', '#FFEF4444',
  '#FFFFFFFF', '#FF000000'
];

/** 单槽位 UI 状态（不可变更新：修改走 clone + 数组重赋值）。 */

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
  private renameGroupController: CustomDialogController | null = null;
  private renameModelController: CustomDialogController | null = null;

  // ==================== 协调器（自本组件抽出的独立子系统） ====================
  /** 截帧状态机（capturing @State 由本组件持有，经回调同步）。 */
  private capture: CaptureCoordinator = new CaptureCoordinator({
    sendCommand: (command: BridgeCommand): void => {
      this.sendCommand(command);
    },
    isWebReady: (): boolean => this.webReady,
    setCapturing: (capturing: boolean): void => {
      this.capturing = capturing;
    },
    onCaptureComplete: (base64: string, purpose: string): void => {
      this.handleCaptureComplete(base64, purpose);
    },
    onCaptureFail: (purpose: string): void => {
      this.handleCaptureFail(purpose);
    }
  });
  /** 缩略图补全管线（串行加载 → 稳帧 → 截帧落盘 → 恢复主模型）。 */
  private thumbPipeline: ThumbPipeline = new ThumbPipeline({
    getContext: (): Context => getContext(this),
    library: (): SpineModelLibrary | null => this.library,
    sendCommand: (command: BridgeCommand): void => {
      this.sendCommand(command);
    },
    startCapture: (purpose: string): void => {
      this.capture.start(purpose);
    },
    isWebReady: (): boolean => this.webReady,
    isCapturing: (): boolean => this.capturing,
    setModelLoading: (loading: boolean): void => {
      this.modelLoading = loading;
    },
    isModelLoading: (): boolean => this.modelLoading,
    setGenerating: (generating: boolean): void => {
      this.thumbGenerating = generating;
    },
    isGenerating: (): boolean => this.thumbGenerating,
    setProgress: (current: number, total: number): void => {
      this.thumbGenCurrent = current;
      this.thumbGenTotal = total;
    },
    getMainModelId: (): string => this.mainModelId,
    getSlotPma: (slot: number): boolean => this.slotUi[slot].pma,
    isMainSlotHidden: (): boolean => !this.slotVisible[0],
    onThumbSaved: (modelId: string): void => {
      this.markThumbGenerated(modelId);
    },
    restoreMainSlot: (mainWasHidden: boolean): void => {
      this.loadSlotModel(0);
      if (mainWasHidden) {
        this.slotVisible[0] = false;
        this.slotVisible = this.slotVisible.slice();
        this.sendCommand({ cmd: BridgeCmdNames.SET_SLOT_VISIBLE, slot: 0, visible: false });
      }
    },
    showResult: (okCount: number, total: number): void => {
      if (okCount === total) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.thumb_gen_done') });
      } else {
        this.getUIContext().getPromptAction().showToast({
          message: $r('app.string.thumb_gen_partial', okCount, total - okCount),
          duration: 3000
        });
      }
    }
  });
  /** 桌面卡片快照与刷新。 */
  private widget: WidgetCoordinator = new WidgetCoordinator({
    getContext: (): Context => getContext(this),
    isAutoUpdateEnabled: (): boolean => this.widgetAutoUpdate,
    isThumbGenerating: (): boolean => this.thumbGenerating,
    isCapturing: (): boolean => this.capturing,
    isWebReady: (): boolean => this.webReady,
    getMainModelId: (): string => this.mainModelId,
    getMainModelName: (): string => this.currentMainModelName(),
    setCapturing: (capturing: boolean): void => {
      this.capturing = capturing;
    },
    markThumbGenerated: (modelId: string): void => {
      this.markThumbGenerated(modelId);
    },
    startCapture: (purpose: string): void => {
      this.capture.start(purpose);
    },
    showToast: (message: ResourceStr): void => {
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  });
  /** 回收站动作（弹窗与列表状态仍在本组件）。 */
  private trash: TrashCoordinator = new TrashCoordinator({
    getContext: (): Context => getContext(this),
    library: (): SpineModelLibrary | null => this.library,
    showToast: (message: ResourceStr): void => {
      this.getUIContext().getPromptAction().showToast({ message: message });
    },
    reloadModels: (): void => {
      this.reloadModels();
    },
    refreshTrashEntries: (): void => {
      this.refreshTrashEntries();
    }
  });

  @State models: Array<SpineModelItem> = [];
  @State importing: boolean = false;
  /** 批量导入进度显示（"done/total"，空串表示无进度）。 */
  @State importProgress: string = '';
  /** 用户请求取消当前批量导入（在当前 ZIP 边界生效）。 */
  private cancelImportRequested: boolean = false;
  @State selectedSlot: number = 0;
  @State playing: boolean = true;
  /** 当前 HdsTabs 页索引（0 播放 / 1 模型库 / 2 设置），常亮窗口联动用。 */
  private currentTabIndex: number = 0;
  private pausedByHide: boolean = false;
  @State fps: number = 60;
  @State tapSwitch: boolean = true;
  /** 全局动画过渡混合秒数（0-0.5，默认 0.2）。 */
  @State animationMix: number = 0.2;
  @State widgetAutoUpdate: boolean = false;
  /** 播放页屏幕常亮（默认开，设置页可关）。 */
  @State keepScreenOn: boolean = true;
  /** 定时随机轮换动画开关（默认关，设置页调整）。 */
  @State rotationEnabled: boolean = false;
  /** 轮换间隔（秒，10-600 钳制，默认 60）。 */
  @State rotationIntervalSec: number = 60;
  /** 轮换定时器 id（-1 表示未运行）。 */
  private rotationTimerId: number = -1;
  @State bgColor: string = '#0F172A';
  /** 背景图文件名（<filesDir>/bg/ 内，空串表示未设置）。 */
  @State bgImageName: string = '';
  @State capturing: boolean = false;
  /** 沉浸模式：控制条收起状态（内存态，每次启动默认显示）。 */
  @State controlBarVisible: boolean = true;
  /** 底部悬浮栏材质档位（aboutToAppear 按设备能力探测，默认 ADAPTIVE）。 */
  @State barMaterialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.ADAPTIVE;
  /** 槽位模型显隐（会话级，不持久化；进 App 默认双显）。 */
  @State slotVisible: Array<boolean> = [true, true];
  /** 缩略图补全管线运行中（抑制 widget 自动截帧）。 */
  @State thumbGenerating: boolean = false;
  /** 缩略图管线进度（横幅显示用）。 */
  @State thumbGenCurrent: number = 0;
  @State thumbGenTotal: number = 0;
  /** 主模型加载遮罩（LOAD_MODEL 发出 → onModelLoaded/onError）。 */
  @State modelLoading: boolean = false;
  @State mainModelId: string = '';
  @State subModelId: string = '';
  @State slotUi: Array<SlotUiState> = [new SlotUiState(), new SlotUiState()];
  /** 库内排序模式：'default' | 'name' | 'time'。 */
  @State librarySort: string = 'default';
  /** 回收站保留策略（天数，0 = 永久保留）。 */
  @State trashRetentionDays: number = 0;
  /** 回收站条目（@State 驱动弹窗 @Link 与标题行徽标数）。 */
  @State trashEntries: Array<TrashEntry> = [];
  /** 回收站弹窗：@Link 必须在字段初始化处绑定 @State 属性（方法内构造拿到裸数组会导致 TwoWay 同步崩溃）。 */
  private trashController: CustomDialogController = new CustomDialogController({
    builder: TrashDialog({
      entries: this.trashEntries,
      onRestore: (modelId: string): void => {
        this.trash.restore(modelId);
      },
      onPurge: (modelId: string): void => {
        this.trash.purge(modelId);
      },
      onEmpty: (): void => {
        this.trash.empty();
      }
    }),
    autoCancel: true
  });
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

    // 探测设备材质档位：支持沉浸光感（IMMERSIVE）则启用，否则保持 ADAPTIVE
    try {
      const supportedMaterials: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      if (supportedMaterials.includes(hdsMaterial.MaterialType.IMMERSIVE)) {
        this.barMaterialType = hdsMaterial.MaterialType.IMMERSIVE;
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(LOG_DOMAIN, TAG, `getSystemMaterialTypes failed: ${err.code} ${err.message}`);
    }

    this.bridge.modelLoadedHandler = (json: string): void => {
      this.handleModelLoaded(json);
    };
    this.bridge.errorHandler = (json: string): void => {
      this.handleBridgeError(json);
    };
    this.bridge.captureChunkHandler = (json: string): void => {
      this.capture.handleChunk(json);
    };
    this.bridge.captureDoneHandler = (json: string): void => {
      this.capture.handleDone(json);
    };
    this.bridge.transformChangedHandler = (json: string): void => {
      this.handleTransformChanged(json);
    };
    this.bridge.animationChangedHandler = (json: string): void => {
      this.handleAnimationChanged(json);
    };
    this.bridge.screenTapHandler = (): void => {
      // 画布点按（Web touchend tap 分支上报）→ 沉浸：收起悬浮控制条
      this.controlBarVisible = false;
    };

    this.prefs = await PrefsManager.getInstance(context);
    this.library = SpineModelLibrary.getInstance(context);
    await this.library.loadModels();
    this.reloadModels();

    const prefs = this.prefs;
    this.librarySort = this.normalizeSortMode(prefs.getString(PrefsKeys.LIBRARY_SORT, 'default'));
    this.trashRetentionDays = prefs.getNumber(PrefsKeys.TRASH_RETENTION_DAYS, 0);
    this.refreshTrashEntries();
    this.trash.purgeExpired(this.trashRetentionDays);
    this.mainModelId = prefs.getString(PrefsKeys.ACTIVE_MODEL_ID, '');
    this.subModelId = prefs.getString(PrefsKeys.MODEL2_ID, '');
    this.selectedSlot = prefs.getNumber(PrefsKeys.SELECTED_SLOT, 0) === 1 ? 1 : 0;
    this.playing = true;
    this.fps = clampInt(prefs.getNumber(PrefsKeys.TARGET_FPS, 60), 15, 120);
    this.tapSwitch = prefs.getBool(PrefsKeys.TAP_SWITCH_ANIMATION, true);
    this.animationMix = clampFloat2(prefs.getNumber(PrefsKeys.ANIMATION_MIX, 0.2), 0, 0.5);
    this.widgetAutoUpdate = prefs.getBool(PrefsKeys.WIDGET_AUTO_UPDATE, false);
    this.keepScreenOn = prefs.getBool(PrefsKeys.KEEP_SCREEN_ON, true);
    this.applyKeepScreenOn();
    this.rotationEnabled = prefs.getBool(PrefsKeys.ANIMATION_ROTATION_ENABLED, false);
    this.rotationIntervalSec = clampInt(prefs.getNumber(PrefsKeys.ANIMATION_ROTATION_INTERVAL, 60), 10, 600);
    this.updateRotationTimer();
    this.bgColor = intColorToHex(prefs.getNumber(PrefsKeys.BG_COLOR, PrefsManager.defaultBgColor));
    this.bgImageName = prefs.getString(PrefsKeys.BG_IMAGE_PATH, '');
    this.bgFavorites = this.loadBgFavorites(prefs);
    AppStorage.setOrCreate('themeDark', prefs.getString(PrefsKeys.THEME_MODE, 'dark') !== 'light');
    this.initSlotUi(0);
    this.initSlotUi(1);
  }

  aboutToDisappear(): void {
    this.clearRotationTimer();
    this.capture.dispose();
    this.widget.dispose();
  }

  onPageHide(): void {
    if (this.playing) {
      this.pausedByHide = true;
      this.playing = false;
      this.sendCommand({ cmd: BridgeCmdNames.SET_PLAYING, playing: false });
      this.updateRotationTimer();
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
        this.updateRotationTimer();
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

          // 主模型加载遮罩
          if (this.modelLoading) {
            Column({ space: 12 }) {
              LoadingProgress()
                .width(44)
                .height(44)
                .color(this.theme().accent)
              Text($r('app.string.model_loading'))
                .fontSize(13)
                .fontColor(this.theme().textSecondary)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor('rgba(0,0,0,0.35)')
          }

          // 悬浮控制条（避开底部悬浮页签栏）+ 沉浸模式把手（收起/展开控制条）
          Column({ space: 6 }) {
            if (this.controlBarVisible) {
              ControlBar({
                slot: this.selectedSlot,
                playing: this.playing,
                capturing: this.capturing,
                animations: this.slotUi[this.selectedSlot].animations,
                currentAnimation: this.slotUi[this.selectedSlot].currentAnimation,
                skins: this.slotUi[this.selectedSlot].skins,
                selectedSkins: this.slotUi[this.selectedSlot].selectedSkins,
                slot0Visible: this.slotVisible[0],
                slot1Visible: this.slotVisible[1],
                mirrored: this.slotUi[this.selectedSlot].mirrored,
                playlist: this.slotUi[this.selectedSlot].playlist,
                playlistEnabled: this.slotUi[this.selectedSlot].playlistEnabled,
                onSlotChange: (slot: number): void => {
                  this.switchSlot(slot);
                },
                onSlotToggleVisible: (slot: number): void => {
                  this.toggleSlotVisible(slot);
                },
                onTogglePlay: (): void => {
                  this.togglePlay();
                },
                onToggleMirror: (): void => {
                  this.toggleMirror();
                },
                onAnimationPick: (name: string): void => {
                  this.pickAnimation(this.selectedSlot, name, true);
                },
                onPlaylistModeToggle: (): void => {
                  this.togglePlaylistMode();
                },
                onPlaylistItemToggle: (name: string): void => {
                  this.togglePlaylistItem(name);
                },
                onSkinToggle: (name: string): void => {
                  this.toggleSkin(name);
                },
                onCapture: (): void => {
                  this.capture.start(CAPTURE_PURPOSE_GALLERY);
                },
                onResetTransform: (): void => {
                  this.resetTransform();
                },
                onClearSlot: (): void => {
                  this.clearSlotModel(this.selectedSlot);
                }
              })
              .width('100%')
              .transition(TransitionEffect.translate({ y: 160 })
                .combine(TransitionEffect.OPACITY)
                .animation({ duration: 250, curve: Curve.Friction }))
            }
            Button() {
              SymbolGlyph(this.controlBarVisible ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_up'))
                .fontSize(12)
                .fontColor([this.theme().text])
            }
            .width(48)
            .height(18)
            .borderRadius(9)
            .backgroundColor(this.theme().chip)
            .opacity(0.8)
            .padding(0)
            .accessibilityText(this.controlBarVisible
              ? $r('app.string.a11y_hide_controls')
              : $r('app.string.a11y_show_controls'))
            .onClick(() => {
              this.controlBarVisible = !this.controlBarVisible;
            })
          }
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 96 })

          // 底部上滑手势区：展开被点按隐藏的控制条（悬浮页签栏两侧及上方区域可触发；
          // 96vp 正好覆盖底部 Column 的 padding 空带，不遮挡把手与控制条）
          Row()
            .width('100%')
            .height(96)
            .backgroundColor(Color.Transparent)
            .hitTestBehavior(HitTestMode.Transparent)
            .gesture(PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 8 })
              .onActionEnd((event: GestureEvent): void => {
                if (event.offsetY < -20 && !this.controlBarVisible) {
                  this.controlBarVisible = true;
                }
              }))
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
          importProgress: this.importProgress,
          thumbGenerating: this.thumbGenerating,
          thumbGenCurrent: this.thumbGenCurrent,
          thumbGenTotal: this.thumbGenTotal,
          onGenerateThumbs: (ids: Array<string>): void => {
            this.thumbPipeline.generate(ids);
          },
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
          },
          onRenameGroup: (group: string): void => {
            this.renameGroupAction(group);
          },
          onDeleteModels: (ids: Array<string>): void => {
            this.deleteModelsAction(ids);
          },
          onOpenTrash: (): void => {
            this.openTrashAction();
          },
          onRenameModel: (modelId: string): void => {
            this.renameModelAction(modelId);
          },
          onSortChange: (mode: string): void => {
            this.changeLibrarySort(mode);
          },
          sortMode: this.librarySort,
          trashCount: this.trashEntries.length
        })
      }
      .tabBar({ icon: $r('app.media.tab_library'), text: $r('app.string.tab_library') })

      TabContent() {
        SettingsPage({
          pmaMain: this.slotUi[0].pma,
          pmaSub: this.slotUi[1].pma,
          tapSwitch: this.tapSwitch,
          fps: this.fps,
          widgetAutoUpdate: this.widgetAutoUpdate,
          keepScreenOn: this.keepScreenOn,
          rotationEnabled: this.rotationEnabled,
          rotationInterval: this.rotationIntervalSec,
          alphaMain: this.slotUi[0].alpha,
          alphaSub: this.slotUi[1].alpha,
          speedMain: this.slotUi[0].speed,
          speedSub: this.slotUi[1].speed,
          animationMix: this.animationMix,
          trashRetentionDays: this.trashRetentionDays,
          onPmaMainChange: (pma: boolean): void => {
            this.togglePma(0, pma);
          },
          onPmaSubChange: (pma: boolean): void => {
            this.togglePma(1, pma);
          },
          onTapSwitchChange: (enabled: boolean): void => {
            this.toggleTapSwitch(enabled);
          },
          onFpsChange: (fps: number): void => {
            this.changeFps(fps);
          },
          onWidgetAutoUpdateChange: (enabled: boolean): void => {
            this.toggleWidgetAutoUpdate(enabled);
          },
          onKeepScreenOnChange: (enabled: boolean): void => {
            this.toggleKeepScreenOn(enabled);
          },
          onRotationEnabledChange: (enabled: boolean): void => {
            this.toggleRotation(enabled);
          },
          onRotationIntervalChange: (sec: number): void => {
            this.changeRotationInterval(sec);
          },
          onAlphaMainChange: (percent: number): void => {
            this.setSlotAlpha(0, percent);
          },
          onAlphaSubChange: (percent: number): void => {
            this.setSlotAlpha(1, percent);
          },
          onSpeedMainChange: (speed: number): void => {
            this.setSlotSpeed(0, speed);
          },
          onSpeedSubChange: (speed: number): void => {
            this.setSlotSpeed(1, speed);
          },
          onMixChange: (mix: number): void => {
            this.setAnimationMix(mix);
          },
          onTrashRetentionChange: (days: number): void => {
            this.trashRetentionDays = days;
            this.prefs?.putNumber(PrefsKeys.TRASH_RETENTION_DAYS, days);
            this.prefs?.flush();
          },
          onUpdateWidgetNow: (): void => {
            this.widget.updateNow();
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
    .barFloatingStyle({
      barSideMargin: 16,
      barBottomMargin: 12,
      // 沉浸光感材质（设备不支持时 aboutToAppear 已降级为 ADAPTIVE）
      systemMaterialEffect: {
        materialType: this.barMaterialType,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    .onChange((index: number) => {
      this.handleTabChange(index);
    })
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme().pageBg)
  }

  /** 切离播放页暂停渲染，切回恢复（同 onPageHide/resumeAfterOverlay 模式）。 */
  private handleTabChange(index: number): void {
    this.currentTabIndex = index;
    this.applyKeepScreenOn();
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
    // playing/页签均可能变化，须在状态收敛后重估轮换定时器
    this.updateRotationTimer();
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
    this.sendCommand({ cmd: BridgeCmdNames.SET_MIX, mix: this.animationMix });
    this.sendCommand({ cmd: BridgeCmdNames.SET_BG_COLOR, color: this.bgColor });
    if (this.bgImageName.length > 0) {
      this.sendCommand({ cmd: BridgeCmdNames.SET_BG_IMAGE, url: `/bg/${this.bgImageName}` });
    }
    this.sendCommand({ cmd: BridgeCmdNames.SET_PLAYING, playing: this.playing });
    this.sendCommand({ cmd: BridgeCmdNames.SET_TAP_SWITCH, tapSwitch: this.tapSwitch });
    // Web 页面重载后显隐状态对齐（SlotState.reset 默认可见，此处按 ArkTS 侧状态重放）
    this.sendCommand({ cmd: BridgeCmdNames.SET_SLOT_VISIBLE, slot: 0, visible: this.slotVisible[0] });
    this.sendCommand({ cmd: BridgeCmdNames.SET_SLOT_VISIBLE, slot: 1, visible: this.slotVisible[1] });
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
    // Web 端加载/清空均会置槽位为可见（加载即显示），ArkTS 侧状态同步
    this.slotVisible[slot] = true;
    this.slotVisible = this.slotVisible.slice();
    const modelId = slot === 0 ? this.mainModelId : this.subModelId;
    if (modelId.length === 0) {
      if (slot === 0) {
        this.modelLoading = false;
      }
      this.sendCommand({ cmd: BridgeCmdNames.CLEAR_SLOT, slot: slot });
      return;
    }
    const model = library.getModelById(modelId);
    if (model === null) {
      if (slot === 0) {
        this.modelLoading = false;
      }
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
    if (slot === 0) {
      this.modelLoading = true;
    }
    // config.json tap_motions → [{area, anim}]（bounding box 命中区域 → 反应动画）
    const tapMotions = new Array<TapMotionEntry>();
    if (config !== null && config.tap_motions.size > 0) {
      config.tap_motions.forEach((anim: string, area: string): void => {
        tapMotions.push({ area: area, anim: anim });
      });
    }
    this.sendCommand({
      cmd: BridgeCmdNames.LOAD_MODEL,
      slot: slot,
      modelId: model.id,
      skelFile: model.skelFile,
      atlasFile: atlasFile,
      version: model.version,
      pma: ui.pma,
      configScale: config !== null ? config.scale : 1,
      idleMotion: config !== null ? config.idle_motion : '',
      tapMotions: tapMotions
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
    // Web 端 LOAD_MODEL 会 reset（mirrored=false，缩略图管线默认朝向）→ 重载后恢复用户翻转偏好
    this.sendCommand({ cmd: BridgeCmdNames.SET_MIRROR, slot: slot, mirror: ui.mirrored });
    // 同理：reset 使 alpha 归 1 → 重载后恢复用户透明度偏好
    this.sendCommand({ cmd: BridgeCmdNames.SET_ALPHA, slot: slot, alpha: ui.alpha / 100 });
    // 槽位播放速度恢复（Web 端 reset 归 1）
    this.sendCommand({ cmd: BridgeCmdNames.SET_SPEED, slot: slot, speed: ui.speed });
    // 循环轮播列表恢复（Web 端 reset 清空）
    this.sendCommand({
      cmd: BridgeCmdNames.SET_PLAYLIST,
      slot: slot,
      names: ui.playlist,
      enabled: ui.playlistEnabled
    });
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
    const mirrored = prefs.getBool(SlotPrefs.mirrorKey(slot), false);
    const alpha = clampInt(prefs.getNumber(SlotPrefs.alphaKey(slot), 100), 10, 100);
    const speed = clampFloat2(prefs.getNumber(SlotPrefs.speedKey(slot), 1), 0.25, 2);
    const playlistPrefs = prefs.getPlaylist(SlotPrefs.playlistJsonKey(slot));
    this.updateSlotUi(slot, (state: SlotUiState): void => {
      state.animations = animations;
      state.skins = skins;
      state.currentAnimation = currentAnimation;
      state.selectedSkins = effectiveSkins;
      state.pma = pma;
      state.mirrored = mirrored;
      state.alpha = alpha;
      state.speed = speed;
      state.playlist = playlistPrefs.names;
      state.playlistEnabled = playlistPrefs.enabled;
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
    if (event.slot === 0) {
      this.modelLoading = false;
    }
    if (this.library !== null) {
      this.library.updateModelAnimSkins(event.modelId, event.animations, event.skins);
      this.reloadModels();
    }
    // 缩略图管线临时加载（槽 0 非主模型）：仅回填库元数据，不改动槽位 UI 状态、
    // 不回写偏好——避免临时模型的动画/皮肤/轮播覆盖主模型的持久化偏好。
    // Web 侧自行解析默认动画（desired > idle_motion > first）用于截帧。
    if (this.thumbGenerating && event.slot === 0 && event.modelId !== this.mainModelId) {
      return;
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
      // 轮播列表校正：过滤已不存在的动画名（SKEL 占位 meta 场景靠真实动画名校正）
      const keptPlaylist = state.playlist.filter((name: string): boolean => event.animations.includes(name));
      if (keptPlaylist.length !== state.playlist.length) {
        state.playlist = keptPlaylist;
        if (keptPlaylist.length === 0) {
          state.playlistEnabled = false;
        }
      }
    });
    const ui = this.slotUi[event.slot];
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putString(SlotPrefs.animationKey(event.slot), ui.currentAnimation);
      prefs.putSelectedSkins(SlotPrefs.skinsJsonKey(event.slot), ui.selectedSkins);
      prefs.putPlaylist(SlotPrefs.playlistJsonKey(event.slot), new PlaylistPrefs(ui.playlistEnabled, ui.playlist));
      prefs.flush();
    }
    // 加载后校正动画与皮肤（偏好中的名称可能已不存在）
    this.sendCommand({ cmd: BridgeCmdNames.PLAY_ANIMATION, slot: event.slot, name: ui.currentAnimation, loop: true });
    this.sendCommand({ cmd: BridgeCmdNames.SET_SKINS, slot: event.slot, skins: ui.selectedSkins });
    // 轮播列表校正后重发（Web 端按真实动画名解析并启播）
    this.sendCommand({
      cmd: BridgeCmdNames.SET_PLAYLIST,
      slot: event.slot,
      names: ui.playlist,
      enabled: ui.playlistEnabled
    });
    if (this.widgetAutoUpdate) {
      this.widget.scheduleCapture();
    }
  }

  private handleBridgeError(json: string): void {
    const event = parseBridgeErrorEvent(json);
    if (event === null) {
      return;
    }
    hilog.error(LOG_DOMAIN, TAG, 'bridge error slot=%{public}d code=%{public}s message=%{public}s',
      event.slot, event.code, event.message);
    if (event.slot === 0) {
      this.modelLoading = false;
    }
    if (event.code === 'CAPTURE_ERROR') {
      this.capture.abort();
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
    // 缩略图管线期间槽 0 为临时模型：动画变化不更新 UI、不回写偏好
    // （管线结束后 loadSlotModel(0) 会经 handleModelLoaded 完整重建状态）
    if (this.thumbGenerating && event.slot === 0) {
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

  /** 截帧成功回调（由 CaptureCoordinator 分发，按用途路由）。 */
  private handleCaptureComplete(base64: string, purpose: string): void {
    if (purpose === CAPTURE_PURPOSE_THUMB) {
      this.thumbPipeline.onFrameComplete(base64);
      return;
    }
    if (purpose === CAPTURE_PURPOSE_WIDGET || purpose === CAPTURE_PURPOSE_WIDGET_MANUAL) {
      this.widget.saveSnapshot(base64, purpose === CAPTURE_PURPOSE_WIDGET_MANUAL);
      return;
    }
    FrameExporter.saveToGallery(getContext(this), base64)
      .then((): void => {
        this.capturing = false;
        this.resumeAfterOverlay();
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_capture_ok') });
        this.widget.updateFromFrame(base64);
      })
      .catch((err: BusinessError): void => {
        this.capturing = false;
        this.resumeAfterOverlay();
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_capture_fail') });
      });
  }

  /** 截帧失败/超时回调（按用途路由，避免缩略图管线悬挂）。 */
  private handleCaptureFail(purpose: string): void {
    if (purpose === CAPTURE_PURPOSE_THUMB) {
      this.thumbPipeline.resolveCapture(false);
      return;
    }
    if (purpose === CAPTURE_PURPOSE_WIDGET || purpose === CAPTURE_PURPOSE_WIDGET_MANUAL) {
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_capture_fail') });
  }

  // ==================== 用户操作 ====================

  private async importModels(): Promise<void> {
    if (this.importing) {
      // 导入中再次点击 = 请求在当前 ZIP 边界取消
      this.cancelImportRequested = true;
      return;
    }
    const docPicker = new picker.DocumentViewPicker(getContext(this));
    const options = new picker.DocumentSelectOptions();
    options.fileSuffixFilters = ['.zip'];
    options.maxSelectNumber = 500;
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
    this.pickImportGroup(uris);
  }

  /** 导入前选择分组（记忆上次选择，整批仅弹一次），确定后执行批量导入。 */
  private pickImportGroup(zipUris: Array<string>): void {
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
          this.runBatchImport(zipUris, group);
        }
      }),
      autoCancel: true
    });
    this.groupPickerController.open();
  }

  private async runBatchImport(zipUris: Array<string>, fallbackGroup: string): Promise<void> {
    const library = this.library;
    if (library === null) {
      return;
    }
    this.importing = true;
    this.importProgress = '';
    this.cancelImportRequested = false;
    try {
      const result: BatchImportResult = await library.importBatch(zipUris, fallbackGroup,
        (done: number, total: number): void => {
          this.importProgress = `${done}/${total}`;
        },
        (): boolean => this.cancelImportRequested);
      this.reloadModels();
      this.showImportResultToast(result);
      if (result.importedIds.length > 0) {
        // 导入钩子：新导入模型自动补缩略图（管线串行，完成后恢复主模型）
        this.thumbPipeline.generate(result.importedIds);
      }
      if (this.mainModelId.length === 0 && result.firstImportedId.length > 0) {
        this.applyModelSelection(0, result.firstImportedId);
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : '';
      this.getUIContext().getPromptAction().showToast({
        message: message.length > 0 ? message : $r('app.string.toast_import_fail')
      });
    } finally {
      this.importing = false;
      this.importProgress = '';
    }
  }

  /** 导入结果汇总 toast：成功/跳过重复/取消/失败拼接，混合结果 3500ms。 */
  private showImportResultToast(result: BatchImportResult): void {
    const parts = new Array<string>();
    if (result.importedCount > 0) {
      parts.push(`成功 ${result.importedCount} 个`);
    }
    if (result.skippedDuplicates > 0) {
      parts.push(`跳过重复 ${result.skippedDuplicates} 个`);
    }
    if (result.cancelled) {
      parts.push('已取消导入');
    }
    if (result.failedZips.length > 0) {
      parts.push(`失败 ${result.failedZips.length} 个：${result.failedZips.join('、')}`);
    }
    if (parts.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_import_fail') });
      return;
    }
    // 纯成功保持原有短提示，其余拼接成长提示
    if (result.failedZips.length === 0 && result.skippedDuplicates === 0 &&
      !result.cancelled && result.importedCount > 0) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_import_ok') });
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: parts.join('，'), duration: 3500 });
  }

  /** 选择模型到指定槽位（运行时版本门禁：已集成 3.8 / 4.0 / 4.1 / 4.2 + 偏好持久化 + 下发加载）。 */
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

  /** 清空槽位模型：置空偏好 + 复位槽位 UI + 下发 CLEAR_SLOT（模型仍保留在库中）。 */
  private clearSlotModel(slot: number): void {
    const prefs = this.prefs;
    if (prefs === null) {
      return;
    }
    if (slot === 0) {
      this.mainModelId = '';
      prefs.putString(PrefsKeys.ACTIVE_MODEL_ID, '');
    } else {
      this.subModelId = '';
      prefs.putString(PrefsKeys.MODEL2_ID, '');
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
      message: $r('app.string.confirm_move_to_trash'),
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

  /** 移入回收站：目录搬移保留缩略图，槽位清理，徽标数刷新。 */
  private performDelete(modelId: string): void {
    const library = this.library;
    if (library === null) {
      return;
    }
    library.moveToTrash(modelId)
      .then((): void => {
        this.reloadModels();
        this.refreshTrashEntries();
        this.cleanupSlotsForDeleted(modelId);
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_trash_moved') });
      })
      .catch((err: BusinessError): void => {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_delete_fail') });
      });
  }

  /** 批量移入回收站（确认弹窗已由模型库页面内完成）：串行搬移 → 逐个清理槽位。 */
  private deleteModelsAction(ids: Array<string>): void {
    const library = this.library;
    if (library === null || ids.length === 0) {
      return;
    }
    library.moveModelsToTrash(ids)
      .then((): void => {
        this.reloadModels();
        this.refreshTrashEntries();
        for (const id of ids) {
          this.cleanupSlotsForDeleted(id);
        }
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_trash_moved') });
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

  // ==================== 排序 / 重命名 / 回收站 ====================

  /** 排序模式白名单归一（非法值回退 default）。 */
  private normalizeSortMode(mode: string): string {
    return mode === 'name' || mode === 'time' ? mode : 'default';
  }

  /** 切换库内排序并持久化。 */
  private changeLibrarySort(mode: string): void {
    const normalized = this.normalizeSortMode(mode);
    this.librarySort = normalized;
    this.prefs?.putString(PrefsKeys.LIBRARY_SORT, normalized);
    this.prefs?.flush();
  }

  /** 从回收站索引刷新条目（整体重赋值驱动弹窗 @Link 与徽标数）。 */
  private refreshTrashEntries(): void {
    const library = this.library;
    if (library === null) {
      return;
    }
    this.trashEntries = library.getTrashedModels();
  }

  /** 重命名模型：弹窗预填当前名，确认后持久化。 */
  private renameModelAction(modelId: string): void {
    const library = this.library;
    if (library === null) {
      return;
    }
    const model = library.getModelById(modelId);
    if (model === null) {
      return;
    }
    this.renameModelController = new CustomDialogController({
      builder: RenameModelDialog({
        initialName: model.name,
        confirm: (newName: string): void => {
          library.renameModel(modelId, newName)
            .then((ok: boolean): void => {
              if (ok) {
                this.reloadModels();
                this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_model_renamed') });
              }
            })
            .catch((err: BusinessError): void => {
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_rename_fail') });
            });
        }
      }),
      autoCancel: true
    });
    this.renameModelController.open();
  }

  /** 打开回收站弹窗（先刷新条目再复用字段初始化的控制器）。 */
  private openTrashAction(): void {
    this.refreshTrashEntries();
    this.trashController.open();
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
              this.reloadModels();
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

  /** 重命名分组：弹输入框预填当前名，重名冲突提示。 */
  private renameGroupAction(group: string): void {
    const library = this.library;
    if (library === null || group.length === 0) {
      return;
    }
    this.renameGroupController = new CustomDialogController({
      builder: RenameGroupDialog({
        initialName: group,
        confirm: (newName: string): void => {
          library.renameGroup(group, newName)
            .then((ok: boolean): void => {
              this.reloadModels();
              if (!ok) {
                this.getUIContext().getPromptAction().showToast({
                  message: $r('app.string.toast_group_rename_exists')
                });
              }
            })
            .catch((): void => {
              this.getUIContext().getPromptAction().showToast({
                message: $r('app.string.toast_group_rename_exists')
              });
            });
        }
      }),
      autoCancel: true
    });
    this.renameGroupController.open();
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
              this.reloadModels();
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_group_dissolved') });
            });
        }
      }
    });
  }

  /** 删除分组：弹三选一确认（仅删分组 / 连同模型移入回收站 / 取消）。 */
  private deleteGroupAction(group: string): void {
    const library = this.library;
    if (library === null || group.length === 0) {
      return;
    }
    this.groupDeleteController = new CustomDialogController({
      builder: GroupDeleteDialog({
        groupName: group,
        confirm: (deleteModels: boolean): void => {
          if (deleteModels) {
            // 连同模型删除 → 组内模型整体移入回收站（缩略图保留，可恢复）
            const memberIds = new Array<string>();
            for (const m of this.models) {
              if (m.group === group) {
                memberIds.push(m.id);
              }
            }
            library.moveModelsToTrash(memberIds)
              .then((): void => {
                this.reloadModels();
                this.refreshTrashEntries();
                for (const id of memberIds) {
                  this.cleanupSlotsForDeleted(id);
                }
                this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_trash_moved') });
              })
              .catch((err: BusinessError): void => {
                this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_delete_fail') });
              });
          } else {
            library.deleteGroup(group, false)
              .then((): void => {
                this.reloadModels();
                this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_group_dissolved') });
              })
              .catch((err: BusinessError): void => {
                this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_delete_fail') });
              });
          }
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

  /** 切换槽位模型显隐（pill 点按）：下发 Web 命令；隐藏当前控制目标时自动切到另一槽位。 */
  private toggleSlotVisible(slot: number): void {
    this.slotVisible[slot] = !this.slotVisible[slot];
    this.slotVisible = this.slotVisible.slice();
    this.sendCommand({ cmd: BridgeCmdNames.SET_SLOT_VISIBLE, slot: slot, visible: this.slotVisible[slot] });
    if (!this.slotVisible[slot] && this.selectedSlot === slot) {
      this.switchSlot(slot === 0 ? 1 : 0);
    }
  }

  private togglePlay(): void {
    this.playing = !this.playing;
    this.sendCommand({ cmd: BridgeCmdNames.SET_PLAYING, playing: this.playing });
    this.updateRotationTimer();
  }

  /** 手动选动画（持久化）与轮换切换（会话级）共用：persist=false 时不写偏好。 */
  private pickAnimation(slot: number, name: string, persist: boolean): void {
    this.updateSlotUi(slot, (state: SlotUiState): void => {
      state.currentAnimation = name;
    });
    this.sendCommand({ cmd: BridgeCmdNames.PLAY_ANIMATION, slot: slot, name: name, loop: true });
    const prefs = this.prefs;
    if (persist && prefs !== null) {
      prefs.putString(SlotPrefs.animationKey(slot), name);
      prefs.flush();
    }
  }

  /** 定时随机轮换动画：为显示中的槽位各自随机换一个不同于当前的动画（双槽独立）。 */
  private rotateAnimations(): void {
    // 缩略图管线/截帧期间槽位被临时占用，避让
    if (this.thumbGenerating || this.capturing) {
      return;
    }
    for (let slot = 0; slot < 2; slot++) {
      if (!this.slotVisible[slot]) {
        continue;
      }
      const ui = this.slotUi[slot];
      // 轮播列表启用的槽位已在自动循环，避开定时轮换
      if (ui.playlistEnabled) {
        continue;
      }
      if (ui.animations.length < 2) {
        continue;
      }
      const pool = ui.animations.filter((name: string): boolean => name !== ui.currentAnimation);
      if (pool.length === 0) {
        continue;
      }
      const chosen = pool[Math.floor(Math.random() * pool.length)];
      // 轮换不写偏好：重启后回到手动保存的动画
      this.pickAnimation(slot, chosen, false);
    }
  }

  /** 重估轮换定时器：开启且播放中且在播放页时运行，否则清除。 */
  private updateRotationTimer(): void {
    this.clearRotationTimer();
    if (!this.rotationEnabled || !this.playing || this.currentTabIndex !== 0) {
      return;
    }
    this.rotationTimerId = setInterval((): void => {
      this.rotateAnimations();
    }, this.rotationIntervalSec * 1000);
  }

  private clearRotationTimer(): void {
    if (this.rotationTimerId !== -1) {
      clearInterval(this.rotationTimerId);
      this.rotationTimerId = -1;
    }
  }

  /** 设置页：轮换开关（持久化 + 定时器重估）。 */
  private toggleRotation(enabled: boolean): void {
    this.rotationEnabled = enabled;
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putBool(PrefsKeys.ANIMATION_ROTATION_ENABLED, enabled);
      prefs.flush();
    }
    this.updateRotationTimer();
  }

  /** 设置页：轮换间隔秒数（钳制 10-600，持久化 + 定时器重启）。 */
  private changeRotationInterval(sec: number): void {
    const value = clampInt(sec, 10, 600);
    if (value === this.rotationIntervalSec) {
      return;
    }
    this.rotationIntervalSec = value;
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putNumber(PrefsKeys.ANIMATION_ROTATION_INTERVAL, value);
      prefs.flush();
    }
    this.updateRotationTimer();
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

  private togglePma(slot: number, pma: boolean): void {
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

  /** 切换当前控制目标槽位的水平镜像（持久化 + 下发 Web scaleX 取反）。 */
  private toggleMirror(): void {
    const slot = this.selectedSlot;
    this.updateSlotUi(slot, (state: SlotUiState): void => {
      state.mirrored = !state.mirrored;
    });
    const mirrored = this.slotUi[slot].mirrored;
    this.sendCommand({ cmd: BridgeCmdNames.SET_MIRROR, slot: slot, mirror: mirrored });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putBool(SlotPrefs.mirrorKey(slot), mirrored);
      prefs.flush();
    }
  }

  /** 设置页：槽位整体透明度百分比（10-100，持久化 + 下发 Web skeleton.color.a）。 */
  private setSlotAlpha(slot: number, percent: number): void {
    const value = clampInt(Math.round(percent), 10, 100);
    this.updateSlotUi(slot, (state: SlotUiState): void => {
      state.alpha = value;
    });
    this.sendCommand({ cmd: BridgeCmdNames.SET_ALPHA, slot: slot, alpha: value / 100 });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putNumber(SlotPrefs.alphaKey(slot), value);
      prefs.flush();
    }
  }

  /** 设置页：槽位播放速度（0.25-2，两位小数，持久化 + 下发 Web timeScale）。 */
  private setSlotSpeed(slot: number, speed: number): void {
    const value = clampFloat2(speed, 0.25, 2);
    this.updateSlotUi(slot, (state: SlotUiState): void => {
      state.speed = value;
    });
    this.sendCommand({ cmd: BridgeCmdNames.SET_SPEED, slot: slot, speed: value });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putNumber(SlotPrefs.speedKey(slot), value);
      prefs.flush();
    }
  }

  /** 设置页：全局动画过渡混合秒数（0-0.5，持久化 + 下发 Web defaultMix）。 */
  private setAnimationMix(mix: number): void {
    const value = clampFloat2(mix, 0, 0.5);
    if (value === this.animationMix) {
      return;
    }
    this.animationMix = value;
    this.sendCommand({ cmd: BridgeCmdNames.SET_MIX, mix: value });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putNumber(PrefsKeys.ANIMATION_MIX, value);
      prefs.flush();
    }
  }

  /** 控制条：轮播模式开关（当前控制目标槽位，持久化 + 下发）。 */
  private togglePlaylistMode(): void {
    const slot = this.selectedSlot;
    // 无长度门槛：空列表也允许进入多选模式（Web 侧对空列表自动禁用轮播，仅保持底层动画）；
    // 关闭时 Web 侧恢复单动画循环。
    this.updateSlotUi(slot, (state: SlotUiState): void => {
      state.playlistEnabled = !state.playlistEnabled;
    });
    const ui = this.slotUi[slot];
    this.sendCommand({
      cmd: BridgeCmdNames.SET_PLAYLIST,
      slot: slot,
      names: ui.playlist,
      enabled: ui.playlistEnabled
    });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putPlaylist(SlotPrefs.playlistJsonKey(slot), new PlaylistPrefs(ui.playlistEnabled, ui.playlist));
      prefs.flush();
    }
  }

  /** 控制条：轮播列表成员切换（当前控制目标槽位，追加到末尾/移除，持久化 + 下发）。 */
  private togglePlaylistItem(name: string): void {
    const slot = this.selectedSlot;
    this.updateSlotUi(slot, (state: SlotUiState): void => {
      if (state.playlist.includes(name)) {
        state.playlist = state.playlist.filter((item: string): boolean => item !== name);
        if (state.playlist.length === 0) {
          state.playlistEnabled = false;
        }
      } else {
        const next = state.playlist.slice();
        next.push(name);
        state.playlist = next;
      }
    });
    const ui = this.slotUi[slot];
    this.sendCommand({
      cmd: BridgeCmdNames.SET_PLAYLIST,
      slot: slot,
      names: ui.playlist,
      enabled: ui.playlistEnabled
    });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putPlaylist(SlotPrefs.playlistJsonKey(slot), new PlaylistPrefs(ui.playlistEnabled, ui.playlist));
      prefs.flush();
    }
  }

  /** 播放页屏幕常亮开关（持久化；经 window API 应用到主窗口）。 */
  private toggleKeepScreenOn(enabled: boolean): void {
    this.keepScreenOn = enabled;
    this.applyKeepScreenOn();
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putBool(PrefsKeys.KEEP_SCREEN_ON, enabled);
      prefs.flush();
    }
  }

  /** 主窗口常亮（播放页且开关开启时息屏抑制；window 级 API，Stack 无此属性）。 */
  private applyKeepScreenOn(): void {
    const active = this.keepScreenOn && this.currentTabIndex === 0;
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      win.setWindowKeepScreenOn(active);
    }).catch((error: BusinessError): void => {
      hilog.warn(LOG_DOMAIN, TAG, 'setWindowKeepScreenOn failed: %{public}s', error.message);
    });
  }

  private toggleTapSwitch(enabled: boolean): void {
    this.tapSwitch = enabled;
    this.sendCommand({ cmd: BridgeCmdNames.SET_TAP_SWITCH, tapSwitch: enabled });
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putBool(PrefsKeys.TAP_SWITCH_ANIMATION, enabled);
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

  // ==================== 桌面卡片 ====================

  private toggleWidgetAutoUpdate(enabled: boolean): void {
    this.widgetAutoUpdate = enabled;
    this.prefs?.putBool(PrefsKeys.WIDGET_AUTO_UPDATE, enabled);
    this.prefs?.flush();
  }

  // ==================== 模型缩略图 ====================

  /** 从库刷新模型列表并同步缩略图标志（所有库变更后的统一入口）。 */
  private reloadModels(): void {
    const library = this.library;
    if (library === null) {
      return;
    }
    const context: Context = getContext(this);
    const models = library.getModels();
    for (const m of models) {
      m.hasThumb = ThumbStore.hasThumb(context, m.id);
    }
    this.models = models;
  }

  /** 单个模型缩略图落盘后置位标志（数组重赋值触发刷新）。 */
  private markThumbGenerated(modelId: string): void {
    let changed = false;
    for (const m of this.models) {
      if (m.id === modelId && !m.hasThumb) {
        m.hasThumb = true;
        changed = true;
      }
    }
    if (changed) {
      this.models = this.models.slice();
    }
  }

  private currentMainModelName(): string {
    for (const item of this.models) {
      if (item.id === this.mainModelId) {
        return item.name;
      }
    }
    return '';
  }
}

