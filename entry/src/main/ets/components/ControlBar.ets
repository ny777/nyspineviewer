/**
 * 播放页悬浮控制条（双行式）：
 * 行1 = 播放/暂停、水平镜像（当前控制目标槽位，启用高亮）、重置变换、
 *       槽位显隐开关（主/副紧凑单字，点按=显示/隐藏、长按=切换控制目标，靠右）；
 * 行2 = 清空当前槽位图标、截图（SaveButton 安全组件，点击临时授权直存系统图库）、
 *       皮肤多选横向滚动、动画 chip（点按弹菜单，最右）。
 */
import { getTheme, ThemeColors } from '../core/Theme';

@Component
export struct ControlBar {
  @Prop slot: number = 0;
  @Prop playing: boolean = true;
  @Prop capturing: boolean = false;
  @Prop mirrored: boolean = false;
  @Prop animations: Array<string> = [];
  @Prop currentAnimation: string = '';
  @Prop skins: Array<string> = [];
  @Prop selectedSkins: Array<string> = [];
  @Prop slot0Visible: boolean = true;
  @Prop slot1Visible: boolean = true;
  @StorageProp('themeDark') themeDark: boolean = true;

  onSlotChange: (slot: number) => void = (slot: number) => {
  };
  onSlotToggleVisible: (slot: number) => void = (slot: number) => {
  };
  onTogglePlay: () => void = () => {
  };
  onToggleMirror: () => void = () => {
  };
  onAnimationPick: (name: string) => void = (name: string) => {
  };
  onSkinToggle: (name: string) => void = (name: string) => {
  };
  onCapture: () => void = () => {
  };
  onResetTransform: () => void = () => {
  };
  onClearSlot: () => void = () => {
  };

  private theme(): ThemeColors {
    return getTheme(this.themeDark);
  }

  build() {
    Column({ space: 10 }) {
      // 行1：播放/暂停、镜像、重置变换 + 槽位显隐开关（靠右）
      Row({ space: 8 }) {
        // 播放/暂停图标
        Button() {
          SymbolGlyph(this.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
            .fontSize(16)
            .fontColor([this.theme().text])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(this.theme().chip)
        .padding(0)
        .accessibilityText(this.playing ? $r('app.string.pause') : $r('app.string.play'))
        .onClick(() => {
          this.onTogglePlay();
        })

        // 水平镜像图标（当前控制目标槽位，启用=cardSelected 高亮）
        Button() {
          SymbolGlyph($r('sys.symbol.horizontal_flip'))
            .fontSize(16)
            .fontColor([this.mirrored ? Color.White : this.theme().text])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(this.mirrored ? this.theme().cardSelected : this.theme().chip)
        .padding(0)
        .accessibilityText($r('app.string.a11y_mirror'))
        .onClick(() => {
          this.onToggleMirror();
        })

        // 重置变换图标
        Button() {
          SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
            .fontSize(16)
            .fontColor([this.theme().text])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(this.theme().chip)
        .padding(0)
        .accessibilityText($r('app.string.reset_transform'))
        .onClick(() => {
          this.onResetTransform();
        })

        Blank()
          .layoutWeight(1)

        // 槽位显隐开关：主/副紧凑单字拼接 pill（锁定开关），靠右
        // 按下态（显示）=cardSelected 高亮+白字；弹起态（隐藏）=无边框透明底纯文字；
        // 控制目标不再用颜色区分（长按选择，动画名 chip 隐式指示）；点按=切换显隐
        Text($r('app.string.slot_main_short'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .width(32)
          .height(32)
          .backgroundColor(!this.slot0Visible ? Color.Transparent : this.theme().cardSelected)
          .fontColor(this.slot0Visible ? Color.White : this.theme().textSecondary)
          .borderRadius({ topLeft: 16, bottomLeft: 16 })
          .accessibilityText($r('app.string.a11y_slot_vis_main'))
          .onClick(() => {
            this.onSlotToggleVisible(0);
          })
          .gesture(LongPressGesture({ repeat: false })
            .onAction(() => {
              this.onSlotChange(0);
            }))
        Text($r('app.string.slot_sub_short'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .width(32)
          .height(32)
          .backgroundColor(!this.slot1Visible ? Color.Transparent : this.theme().cardSelected)
          .fontColor(this.slot1Visible ? Color.White : this.theme().textSecondary)
          .borderRadius({ topRight: 16, bottomRight: 16 })
          .accessibilityText($r('app.string.a11y_slot_vis_sub'))
          .onClick(() => {
            this.onSlotToggleVisible(1);
          })
          .gesture(LongPressGesture({ repeat: false })
            .onAction(() => {
              this.onSlotChange(1);
            }))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 行2：清空、截图 + 皮肤 chips 滚动 + 动画 chip（最右）
      Row({ space: 8 }) {
        // 清空当前槽位图标
        Button() {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(16)
            .fontColor([this.theme().danger])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(this.theme().chip)
        .padding(0)
        .accessibilityText(this.slot === 0 ? $r('app.string.clear_main_model') : $r('app.string.clear_sub_model'))
        .onClick(() => {
          this.onClearSlot();
        })

        // 截图（SaveButton 安全组件：点击临时授权，直存系统图库）
        SaveButton({ icon: SaveIconStyle.FULL_FILLED, buttonType: ButtonType.Capsule })
          .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
            if (result === SaveButtonOnClickResult.SUCCESS) {
              this.onCapture();
            }
          })

        // 皮肤多选 chips：空间不足时横向滚动
        Scroll() {
          Row({ space: 6 }) {
            ForEach(this.skins, (name: string) => {
              Text(name)
                .fontSize(12)
                .maxLines(1)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(13)
                .backgroundColor(this.selectedSkins.includes(name) ? this.theme().cardSelected : this.theme().chip)
                .fontColor(this.selectedSkins.includes(name) ? Color.White : this.theme().textSecondary)
                .onClick(() => {
                  this.onSkinToggle(name);
                })
            }, (name: string) => name)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .align(Alignment.Center)

        // 动画 chip：点按弹菜单
        Text(this.currentAnimation.length > 0 ? this.currentAnimation : $r('app.string.no_animation'))
          .fontSize(12)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 90 })
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(13)
          .backgroundColor(this.theme().chip)
          .fontColor(this.theme().text)
          .bindMenu(this.AnimationMenuBuilder)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(20)
    .backgroundColor(this.theme().bottomBarBg)
  }

  @Builder
  AnimationMenuBuilder() {
    Menu() {
      ForEach(this.animations, (name: string) => {
        MenuItem({ content: name })
          .onClick(() => {
            this.onAnimationPick(name);
          })
      }, (name: string) => name)
    }
  }
}
