/**
 * 设置页（HdsTabs 第三页）：外观（背景设置入口 + 深色主题）、
 * 播放（PMA + 帧率）、关于（版本说明弹窗）。
 */
import { getTheme, ThemeColors } from '../core/Theme';
import { VersionInfoDialog } from './VersionInfoDialog';

@Component
export struct SettingsPage {
  @Prop pma: boolean = true;
  @Prop @Watch('onFpsPropChange') fps: number = 60;
  @State fpsPreview: number = 60;
  onPmaChange: (pma: boolean) => void = (pma: boolean) => {
  };
  onFpsChange: (fps: number) => void = (fps: number) => {
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
  }

  private onFpsPropChange(): void {
    this.fpsPreview = this.fps;
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
        Text('›')
          .fontSize(18)
          .fontColor(this.theme().textMuted)
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
    }
    .width('100%')
  }

  @Builder
  PlaybackSection() {
    Column() {
      Row({ space: 8 }) {
        Text($r('app.string.pma_label'))
          .fontSize(15)
          .fontColor(this.theme().text)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.pma })
          .onChange((isOn: boolean) => {
            this.onPmaChange(isOn);
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
      Text('ℹ')
        .fontSize(15)
        .fontColor(this.theme().accentSoft)
        .width(24)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .onClick(() => {
      this.versionInfoController.open();
    })
  }
}
