/**
 * 左侧模型库抽屉：导入 ZIP、分组列表（分组头折叠 + 组操作菜单）、模型卡片
 * （版本/格式徽章、分组快捷移动）、设为主/副模型、删除、空库三步引导卡。
 */
import { SpineModelItem } from '../model/SpineModelItem';
import { getTheme, ThemeColors } from '../core/Theme';
import { VersionInfoDialog } from './VersionInfoDialog';

/** 抽屉渲染用分组视图（'' = 未分组，置顶）。 */
export class ModelGroup {
  name: string;
  models: Array<SpineModelItem>;

  constructor(name: string, models: Array<SpineModelItem>) {
    this.name = name;
    this.models = models;
  }
}

@Component
export struct ModelDrawer {
  @Link models: Array<SpineModelItem>;
  @Prop mainModelId: string = '';
  @Prop subModelId: string = '';
  @Prop importing: boolean = false;
  onImport: () => void = () => {
  };
  onSelectMain: (modelId: string) => void = (modelId: string) => {
  };
  onSelectSub: (modelId: string) => void = (modelId: string) => {
  };
  onDelete: (modelId: string) => void = (modelId: string) => {
  };
  onMoveToGroup: (modelId: string) => void = (modelId: string) => {
  };
  onDissolveGroup: (group: string) => void = (group: string) => {
  };
  onDeleteGroup: (group: string) => void = (group: string) => {
  };
  onClose: () => void = () => {
  };
  onToggleTheme: (dark: boolean) => void = (dark: boolean) => {
  };
  @State collapsedGroups: Array<string> = [];
  @StorageProp('themeDark') themeDark: boolean = true;
  private versionInfoController: CustomDialogController = new CustomDialogController({
    builder: VersionInfoDialog({}),
    autoCancel: true,
    customStyle: true
  });

  private theme(): ThemeColors {
    return getTheme(this.themeDark);
  }

  /** 由模型列表派生分组视图：未分组置顶，其余按首现顺序。 */
  private buildGroups(): Array<ModelGroup> {
    let ungrouped: ModelGroup | null = null;
    const named = new Map<string, ModelGroup>();
    for (const m of this.models) {
      if (m.group.length === 0) {
        if (ungrouped === null) {
          ungrouped = new ModelGroup('', new Array<SpineModelItem>());
        }
        ungrouped.models.push(m);
      } else {
        let bucket = named.get(m.group);
        if (bucket === undefined) {
          bucket = new ModelGroup(m.group, new Array<SpineModelItem>());
          named.set(m.group, bucket);
        }
        bucket.models.push(m);
      }
    }
    const result = new Array<ModelGroup>();
    if (ungrouped !== null) {
      result.push(ungrouped);
    }
    named.forEach((bucket: ModelGroup) => {
      result.push(bucket);
    });
    return result;
  }

  private isCollapsed(groupName: string): boolean {
    return this.collapsedGroups.indexOf(groupName) >= 0;
  }

  private toggleCollapse(groupName: string): void {
    const idx = this.collapsedGroups.indexOf(groupName);
    if (idx >= 0) {
      this.collapsedGroups.splice(idx, 1);
    } else {
      this.collapsedGroups.push(groupName);
    }
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text($r('app.string.drawer_title'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme().text)
          .layoutWeight(1)
        Text('✕')
          .fontSize(18)
          .fontColor(this.theme().textSecondary)
          .padding(8)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')

      Button(this.importing ? $r('app.string.importing') : $r('app.string.import_model'))
        .width('100%')
        .backgroundColor(this.theme().importBtn)
        .fontColor(Color.White)
        .enabled(!this.importing)
        .onClick(() => {
          this.onImport();
        })

      if (this.models.length === 0) {
        this.EmptyGuide()
      } else {
        List({ space: 10 }) {
          ForEach(this.buildGroups(), (group: ModelGroup) => {
            ListItem() {
              Column({ space: 10 }) {
                this.GroupHeader(group)
                if (!this.isCollapsed(group.name)) {
                  ForEach(group.models, (model: SpineModelItem) => {
                    this.ModelCard(model)
                  }, (model: SpineModelItem) => model.id)
                }
              }
              .width('100%')
            }
          }, (group: ModelGroup) => `${group.name}::${group.models.length}::${this.isCollapsed(group.name) ? 'c' : 'o'}`)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }

      Divider()
        .color(this.theme().divider)
        .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.theme_dark_label'))
          .fontSize(13)
          .fontColor(this.theme().textSecondary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.themeDark })
          .onChange((isOn: boolean) => {
            this.onToggleTheme(isOn);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Text($r('app.string.version_info_entry'))
          .fontSize(13)
          .fontColor(this.theme().textSecondary)
          .layoutWeight(1)
        Text('ℹ')
          .fontSize(14)
          .fontColor(this.theme().accentSoft)
          .width(24)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.versionInfoController.open();
      })
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor(this.theme().drawerBg)
  }

  /** 空库三步引导卡（功能 9）：标题 + 三步说明 + 大号导入按钮。 */
  @Builder
  EmptyGuide() {
    Column({ space: 14 }) {
      Column({ space: 10 }) {
        Text($r('app.string.empty_guide_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme().text)
          .textAlign(TextAlign.Center)
        Column({ space: 8 }) {
          Text($r('app.string.empty_guide_step1'))
          Text($r('app.string.empty_guide_step2'))
          Text($r('app.string.empty_guide_step3'))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(14)
        .borderRadius(12)
        .backgroundColor(this.theme().card)
      }
      .alignItems(HorizontalAlign.Center)

      Button($r('app.string.empty_guide_btn'))
        .width('100%')
        .height(44)
        .fontSize(15)
        .backgroundColor(this.theme().importBtn)
        .fontColor(Color.White)
        .onClick(() => {
          this.onImport();
        })
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .width('100%')
  }

  /** 分组头：折叠箭头 + 名称 + 数量 + 组操作 ⋮ 菜单。 */
  @Builder
  GroupHeader(group: ModelGroup) {
    Row({ space: 8 }) {
      Text(this.isCollapsed(group.name) ? '▸' : '▾')
        .fontSize(12)
        .fontColor(this.theme().textSecondary)
        .width(16)
      Text(group.name.length === 0 ? $r('app.string.group_ungrouped') : group.name)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme().textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(`${group.models.length}`)
        .fontSize(11)
        .fontColor(this.theme().badgeText)
        .backgroundColor(this.theme().badgeBg)
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(8)
      if (group.name.length > 0) {
        Text('⋮')
          .fontSize(16)
          .fontColor(this.theme().textSecondary)
          .width(24)
          .textAlign(TextAlign.Center)
          .bindMenu([
            {
              value: $r('app.string.menu_dissolve_group'),
              action: (): void => {
                this.onDissolveGroup(group.name);
              }
            },
            {
              value: $r('app.string.menu_delete_group'),
              action: (): void => {
                this.onDeleteGroup(group.name);
              }
            }
          ])
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 2, bottom: 2 })
    .onClick(() => {
      this.toggleCollapse(group.name);
    })
  }

  @Builder
  ModelCard(model: SpineModelItem) {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 4 }) {
          Text(model.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme().text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            Text(model.version)
              .fontSize(10)
              .fontColor(this.theme().badgeText)
              .backgroundColor(this.theme().badgeBg)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
            Text(model.format)
              .fontSize(10)
              .fontColor(this.theme().badgeText)
              .backgroundColor(this.theme().badgeBg)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
            if (!model.isSupported()) {
              Text($r('app.string.badge_unsupported'))
                .fontSize(10)
                .fontColor(this.theme().badgeWarnText)
                .backgroundColor(this.theme().badgeWarnBg)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(4)
            }
            Text(model.group.length > 0 ? model.group : $r('app.string.group_ungrouped'))
              .fontSize(10)
              .fontColor(this.theme().textSecondary)
              .backgroundColor(this.theme().chip)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 96 })
              .onClick(() => {
                this.onMoveToGroup(model.id);
              })
          }
          .alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('✕')
          .fontSize(16)
          .fontColor(this.theme().textSecondary)
          .padding(6)
          .onClick(() => {
            this.onDelete(model.id);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 8 }) {
        Button($r('app.string.set_main'))
          .layoutWeight(1)
          .fontSize(12)
          .height(32)
          .backgroundColor(model.id === this.mainModelId ? this.theme().cardSelected : this.theme().chip)
          .fontColor(model.id === this.mainModelId ? Color.White : this.theme().textSecondary)
          .onClick(() => {
            this.onSelectMain(model.id);
          })
        Button($r('app.string.set_sub'))
          .layoutWeight(1)
          .fontSize(12)
          .height(32)
          .backgroundColor(model.id === this.subModelId ? this.theme().cardSelected : this.theme().chip)
          .fontColor(model.id === this.subModelId ? Color.White : this.theme().textSecondary)
          .onClick(() => {
            this.onSelectSub(model.id);
          })
      }
      .width('100%')
    }
    .padding(12)
    .borderRadius(12)
    .backgroundColor(this.theme().card)
    .width('100%')
  }
}
