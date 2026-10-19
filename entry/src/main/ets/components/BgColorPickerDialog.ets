/**
 * 背景设置弹窗（@CustomDialog）：HdsColorPicker（GRID/SPECTRUM/SLIDERS + 收藏夹）
 * + 背景图选/删。选色即时生效（onColorSelected → confirm）。
 */
import { HdsColorPicker, HdsColorPickerTabType } from '@kit.UIDesignKit';
import { getTheme, ThemeColors } from '../core/Theme';

@CustomDialog
export struct BgColorPickerDialog {
  controller?: CustomDialogController;
  pickedColor: string = '#0F172A';
  /** 是否已设置自定义背景图（决定是否显示「移除背景图」）。 */
  hasBgImage: boolean = false;
  /** 收藏颜色初始列表（ARGB 十六进制）。 */
  initialFavorites: Array<string> = [];
  confirm: (color: string) => void = (color: string) => {
  };
  favoritesUpdate: (favorites: Array<string>) => void = (favorites: Array<string>) => {
  };
  pickImage: () => void = () => {
  };
  removeImage: () => void = () => {
  };
  @StorageProp('themeDark') themeDark: boolean = true;

  private theme(): ThemeColors {
    return getTheme(this.themeDark);
  }

  build() {
    Column({ space: 16 }) {
      Text($r('app.string.color_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme().text)
        .width('100%')

      HdsColorPicker({
        initialColor: this.pickedColor,
        initialFavoriteColors: this.initialFavorites,
        options: {
          circleRadius: 12,
          tabs: [HdsColorPickerTabType.GRID, HdsColorPickerTabType.SPECTRUM, HdsColorPickerTabType.SLIDERS]
        },
        onColorSelected: (color: string): void => {
          this.confirm(color);
        },
        onFavoriteColorsUpdate: (favorites: Array<string>): void => {
          this.favoritesUpdate(favorites);
        }
      })
      .width('100%')
      .height(380)

      Divider()
        .color(this.theme().divider)
        .width('100%')

      Button($r('app.string.btn_select_bg_image'))
        .width('100%')
        .backgroundColor(this.theme().chip)
        .fontColor(this.theme().text)
        .onClick(() => {
          this.controller?.close();
          this.pickImage();
        })

      if (this.hasBgImage) {
        Button($r('app.string.btn_remove_bg_image'))
          .width('100%')
          .backgroundColor(this.theme().chip)
          .fontColor(this.theme().danger)
          .onClick(() => {
            this.controller?.close();
            this.removeImage();
          })
      }

      Button($r('app.string.btn_close'))
        .width('100%')
        .backgroundColor(this.theme().accent)
        .fontColor(Color.White)
        .onClick(() => {
          this.controller?.close();
        })
    }
    .padding(20)
    .width('92%')
    .backgroundColor(this.theme().dialogBg)
    .borderRadius(16)
  }
}
