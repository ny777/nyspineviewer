/**
 * 设置页（HdsTabs 第三页）：外观（背景设置入口 + 深色主题）、
 * 播放（PMA + 帧率）、桌面卡片（自动更新 + 立即更新）、关于（版本说明弹窗）。
 */
import { getTheme, ThemeColors } from '../core/Theme';
import { VersionInfoDialog } from './VersionInfoDialog';

@Component
export struct SettingsPage {
  @Prop pmaMain: boolean = true;
  @Prop pmaSub: boolean = true;
  @Prop tapSwitch: boolean = true;
  @Prop @Watch('onFpsPropChange') fps: number = 60;
  @Prop widgetAutoUpdate: boolean = false;
  @Prop keepScreenOn: boolean = true;
  @Prop rotationEnabled: boolean = false;
  @Prop @Watch('onRotationIntervalPropChange') rotationInterval: number = 60;
  @Prop @Watch('onAlphaMainPropChange') alphaMain: number = 100;
  @Prop @Watch('onAlphaSubPropChange') alphaSub: number = 100;
  @State fpsPreview: number = 60;
  @State rotationPreview: number = 60;
  @State alphaMainPreview: number = 100;
  @State alphaSubPreview: number = 100;
  onPmaMainChange: (pma: boolean) => void = (pma: boolean) => {
  };
  onPmaSubChange: (pma: boolean) => void = (pma: boolean) => {
  };
  onTapSwitchChange: (enabled: boolean) => void = (enabled: boolean) => {
  };
  onFpsChange: (fps: number) => void = (fps: number) => {
  };
  onWidgetAutoUpdateChange: (enabled: boolean) => void = (enabled: boolean) => {
  };
  onKeepScreenOnChange: (enabled: boolean) => void = (enabled: boolean) => {
  };
  onRotationEnabledChange: (enabled: boolean) => void = (enabled: boolean) => {
  };
  onRotationIntervalChange: (sec: number) => void = (sec: number) => {
  };
  onAlphaMainChange: (percent: number) => void = (percent: number) => {
  };
  onAlphaSubChange: (percent: number) => void = (percent: number) => {
  };
  onUpdateWidgetNow: () => void = () => {
  };
  onToggleTheme: (dark: boolean) => void = (dark: boolean) => {
  };
  onOpenBgSettings: () => void = () => {
  };
  @StorageProp('themeDark') themeDark: boolean = true;
  private versionInfoController: CustomDialogController = new CustomDialogController({
    builder: VersionInfoDialog({}),
    autoCancel: true,
    customStyle: true
  });

  private theme(): ThemeColors {
    return getTheme(this.themeDark);
  }

  aboutToAppear(): void {
    this.fpsPreview = this.fps;
    this.rotationPreview = this.rotationInterval;
    this.alphaMainPreview = this.alphaMain;
    this.alphaSubPreview = this.alphaSub;
  }

  private onFpsPropChange(): void {
    this.fpsPreview = this.fps;
  }

  private onRotationIntervalPropChange(): void {
    this.rotationPreview = this.rotationInterval;
  }

  private onAlphaMainPropChange(): void {
    this.alphaMainPreview = this.alphaMain;
  }

  private onAlphaSubPropChange(): void {
    this.alphaSubPreview = this.alphaSub;
  }

  /** 轮换间隔预览：<60 秒 → "N 秒"；整分 → "N 分钟"；否则 → "M 分 S 秒"。 */
  private formatInterval(sec: number): Resource {
    if (sec < 60) {
      return $r('app.string.interval_unit_seconds', sec);
    }
    if (sec % 60 === 0) {
      return $r('app.string.interval_unit_minutes', Math.round(sec / 60));
    }
    return $r('app.string.interval_preview_mix', Math.floor(sec / 60), sec % 60);
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text($r('app.string.settings_section'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme().text)
          .width('100%')

        Column({ space: 4 }) {
          Text($r('app.string.settings_appearance'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme().textMuted)
            .width('100%')
          Column() {
            this.AppearanceSection()
          }
          .width('100%')
          .borderRadius(14)
          .backgroundColor(this.theme().card)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 4 }) {
          Text($r('app.string.settings_playback'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme().textMuted)
            .width('100%')
          Column() {
            this.PlaybackSection()
          }
          .width('100%')
          .borderRadius(14)
          .backgroundColor(this.theme().card)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 4 }) {
          Text($r('app.string.settings_widget_section'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme().textMuted)
            .width('100%')
          Column() {
            this.WidgetSection()
          }
          .width('100%')
          .borderRadius(14)
          .backgroundColor(this.theme().card)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 4 }) {
          Text($r('app.string.settings_about'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme().textMuted)
            .width('100%')
          Column() {
            this.AboutSection()
          }
          .width('100%')
          .borderRadius(14)
          .backgroundColor(this.theme().card)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Auto)
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 100 })
    .backgroundColor(this.theme().pageBg)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  AppearanceSection() {
    Column() {
      Row({ space: 8 }) {
        Text($r('app.string.settings_bg_entry'))
          .fontSize(15)
          .fontColor(this.theme().text)
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([this.theme().textMuted])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .onClick(() => {
        this.onOpenBgSettings();
      })

      Divider()
        .color(this.theme().divider)
        .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.theme_dark_label'))
          .fontSize(15)
          .fontColor(this.theme().text)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.themeDark })
          .onChange((isOn: boolean) => {
            this.onToggleTheme(isOn);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Divider()
        .color(this.theme().divider)
        .width('100%')

      // 模型1整体透明度：拖动只动预览，松手/点击提交（写偏好 + 下发 Web）
      Row({ space: 10 }) {
        Text($r('app.string.settings_alpha_main'))
          .fontSize(15)
          .fontColor(this.theme().text)
        Text($r('app.string.alpha_percent', this.alphaMainPreview))
          .fontSize(14)
          .fontColor(this.theme().textSecondary)
          .constraintSize({ maxWidth: 60 })
          .textAlign(TextAlign.End)
        Slider({ value: this.alphaMain, min: 10, max: 100, step: 5, style: SliderStyle.OutSet })
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.alphaMainPreview = Math.round(value);
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onAlphaMainChange(Math.round(value));
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(this.theme().divider)
        .width('100%')

      // 模型2整体透明度：同上
      Row({ space: 10 }) {
        Text($r('app.string.settings_alpha_sub'))
          .fontSize(15)
          .fontColor(this.theme().text)
        Text($r('app.string.alpha_percent', this.alphaSubPreview))
          .fontSize(14)
          .fontColor(this.theme().textSecondary)
          .constraintSize({ maxWidth: 60 })
          .textAlign(TextAlign.End)
        Slider({ value: this.alphaSub, min: 10, max: 100, step: 5, style: SliderStyle.OutSet })
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.alphaSubPreview = Math.round(value);
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onAlphaSubChange(Math.round(value));
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(this.theme().divider)
        .width('100%')

      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text($r('app.string.settings_tap_switch'))
            .fontSize(15)
            .fontColor(this.theme().text)
          Text($r('app.string.settings_tap_switch_desc'))
            .fontSize(12)
            .fontColor(this.theme().textMuted)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.tapSwitch })
          .onChange((isOn: boolean) => {
            this.onTapSwitchChange(isOn);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  @Builder
  PlaybackSection() {
    Column() {
      Row({ space: 8 }) {
        Text($r('app.string.settings_pma_main'))
          .fontSize(15)
          .fontColor(this.theme().text)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.pmaMain })
          .onChange((isOn: boolean) => {
            this.onPmaMainChange(isOn);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Divider()
        .color(this.theme().divider)
        .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.settings_pma_sub'))
          .fontSize(15)
          .fontColor(this.theme().text)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.pmaSub })
          .onChange((isOn: boolean) => {
            this.onPmaSubChange(isOn);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Divider()
        .color(this.theme().divider)
        .width('100%')

      Row({ space: 10 }) {
        Text($r('app.string.fps_label'))
          .fontSize(15)
          .fontColor(this.theme().text)
        Text(`${this.fpsPreview}`)
          .fontSize(14)
          .fontColor(this.theme().textSecondary)
          .width(32)
          .textAlign(TextAlign.End)
        Slider({ value: this.fps, min: 15, max: 120, step: 1, style: SliderStyle.OutSet })
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.fpsPreview = Math.round(value);
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onFpsChange(Math.round(value));
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 14 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(this.theme().divider)
        .width('100%')

      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text($r('app.string.settings_keep_screen_on'))
            .fontSize(15)
            .fontColor(this.theme().text)
          Text($r('app.string.settings_keep_screen_on_desc'))
            .fontSize(12)
            .fontColor(this.theme().textMuted)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.keepScreenOn })
          .onChange((isOn: boolean) => {
            this.onKeepScreenOnChange(isOn);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(this.theme().divider)
        .width('100%')

      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text($r('app.string.settings_rotation_enabled'))
            .fontSize(15)
            .fontColor(this.theme().text)
          Text($r('app.string.settings_rotation_enabled_desc'))
            .fontSize(12)
            .fontColor(this.theme().textMuted)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.rotationEnabled })
          .onChange((isOn: boolean) => {
            this.onRotationEnabledChange(isOn);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(this.theme().divider)
        .width('100%')

      // 间隔滑杆：开关关闭时半透明弱化，但仍可预调
      Row({ space: 10 }) {
        Text($r('app.string.settings_rotation_interval'))
          .fontSize(15)
          .fontColor(this.theme().text)
        Text(this.formatInterval(this.rotationPreview))
          .fontSize(14)
          .fontColor(this.theme().textSecondary)
          .constraintSize({ maxWidth: 120 })
          .textAlign(TextAlign.End)
        Slider({ value: this.rotationInterval, min: 10, max: 600, step: 5, style: SliderStyle.OutSet })
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            this.rotationPreview = Math.round(value);
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onRotationIntervalChange(Math.round(value));
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 14 })
      .alignItems(VerticalAlign.Center)
      .opacity(this.rotationEnabled ? 1 : 0.4)
    }
    .width('100%')
  }

  @Builder
  WidgetSection() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text($r('app.string.settings_widget_auto_update'))
            .fontSize(15)
            .fontColor(this.theme().text)
          Text($r('app.string.settings_widget_auto_update_desc'))
            .fontSize(12)
            .fontColor(this.theme().textMuted)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.widgetAutoUpdate })
          .onChange((isOn: boolean) => {
            this.onWidgetAutoUpdateChange(isOn);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(this.theme().divider)
        .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.settings_widget_update_now'))
          .fontSize(15)
          .fontColor(this.theme().text)
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(16)
          .fontColor([this.theme().accentSoft])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .onClick(() => {
        this.onUpdateWidgetNow();
      })
    }
    .width('100%')
  }

  @Builder
  AboutSection() {
    Row({ space: 8 }) {
      Text($r('app.string.version_info_entry'))
        .fontSize(15)
        .fontColor(this.theme().text)
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(16)
        .fontColor([this.theme().accentSoft])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .onClick(() => {
      this.versionInfoController.open();
    })
  }
}
