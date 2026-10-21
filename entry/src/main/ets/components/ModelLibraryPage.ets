/**
 * 模型库页（HdsTabs 第二页）：标题行 + 右上角导入（+ 图标 / 导入中取消胶囊）、
 * 置顶搜索栏（清空 / 一键折叠全部 / 管理入口）、分组列表（折叠 + 组操作菜单）、
 * 批量模式（勾选 + 工具栏：全选/已选/删除/完成）、模型卡片（版本/格式徽章、分组快捷移动）、
 * 设为主/副模型、删除、空库三步引导卡。
 */
import { SpineModelItem } from '../model/SpineModelItem';
import { getTheme, ThemeColors } from '../core/Theme';

/** 页面渲染用分组视图（'' = 未分组，置顶）。 */
export class ModelGroup {
  name: string;
  models: Array<SpineModelItem>;

  constructor(name: string, models: Array<SpineModelItem>) {
    this.name = name;
    this.models = models;
  }
}

@Component
export struct ModelLibraryPage {
  @Link models: Array<SpineModelItem>;
  @Prop mainModelId: string = '';
  @Prop subModelId: string = '';
  @Prop importing: boolean = false;
  /** 批量导入进度（"done/total"，空串表示无进度）。 */
  @Prop importProgress: string = '';
  /** 缩略图补全管线运行中（横幅显示进度）。 */
  @Prop thumbGenerating: boolean = false;
  @Prop thumbGenCurrent: number = 0;
  @Prop thumbGenTotal: number = 0;
  onGenerateThumbs: (ids: Array<string>) => void = (ids: Array<string>) => {
  };
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
  onRenameGroup: (group: string) => void = (group: string) => {
  };
  onDeleteModels: (ids: Array<string>) => void = (ids: Array<string>) => {
  };
  @State collapsedGroups: Array<string> = [];
  /** 批量管理模式（勾选删除）。 */
  @State batchMode: boolean = false;
  /** 批量模式已勾选的模型 id。 */
  @State selectedIds: Array<string> = [];
  /** 库内搜索关键字（名称/分组/版本/动画 substring 过滤）。 */
  @State searchQuery: string = '';
  /** 缺图横幅本次会话是否已忽略。 */
  @State thumbBannerDismissed: boolean = false;
  @StorageProp('themeDark') themeDark: boolean = true;

  private theme(): ThemeColors {
    return getTheme(this.themeDark);
  }

  /** 搜索过滤：名称/分组/版本/动画任一 substring 命中（大小写不敏感）。 */
  private filteredModels(): Array<SpineModelItem> {
    const q = this.searchQuery.trim().toLowerCase();
    if (q.length === 0) {
      return this.models;
    }
    return this.models.filter((m: SpineModelItem): boolean =>
      m.name.toLowerCase().includes(q) ||
      m.group.toLowerCase().includes(q) ||
      m.version.toLowerCase().includes(q) ||
      m.animations.some((a: string): boolean => a.toLowerCase().includes(q)));
  }

  /** 由模型列表派生分组视图：未分组置顶，其余按首现顺序。 */
  private buildGroups(): Array<ModelGroup> {
    let ungrouped: ModelGroup | null = null;
    const named = new Map<string, ModelGroup>();
    for (const m of this.filteredModels()) {
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
    this.getUIContext().animateTo({ duration: 220, curve: Curve.Friction }, () => {
      const idx = this.collapsedGroups.indexOf(groupName);
      if (idx >= 0) {
        this.collapsedGroups.splice(idx, 1);
      } else {
        this.collapsedGroups.push(groupName);
      }
    });
  }

  /** 全部分组是否都处于折叠态。 */
  private allGroupsCollapsed(): boolean {
    const groups = this.buildGroups();
    if (groups.length === 0) {
      return true;
    }
    for (const g of groups) {
      if (!this.isCollapsed(g.name)) {
        return false;
      }
    }
    return true;
  }

  /** 一键折叠/展开全部分组：任一展开 → 全折叠；全折叠 → 全展开。 */
  private toggleCollapseAll(): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.Friction }, () => {
      if (this.allGroupsCollapsed()) {
        this.collapsedGroups = [];
        return;
      }
      const names = new Array<string>();
      for (const g of this.buildGroups()) {
        names.push(g.name);
      }
      this.collapsedGroups = names;
    });
  }

  // ==================== 批量管理模式 ====================

  private enterBatch(): void {
    this.selectedIds = [];
    this.batchMode = true;
  }

  private exitBatch(): void {
    this.batchMode = false;
    this.selectedIds = [];
  }

  private isSelected(modelId: string): boolean {
    return this.selectedIds.indexOf(modelId) >= 0;
  }

  /** 当前过滤结果是否已全部勾选。 */
  private isFilteredAllSelected(): boolean {
    const filtered = this.filteredModels();
    if (filtered.length === 0) {
      return false;
    }
    for (const m of filtered) {
      if (!this.isSelected(m.id)) {
        return false;
      }
    }
    return true;
  }

  /** 全选/取消全选（仅作用于当前过滤结果）。 */
  private toggleSelectAll(): void {
    const filtered = this.filteredModels();
    if (this.isFilteredAllSelected()) {
      const remaining = new Array<string>();
      for (const id of this.selectedIds) {
        const stillVisible = filtered.some((m: SpineModelItem): boolean => m.id === id);
        if (!stillVisible) {
          remaining.push(id);
        }
      }
      this.selectedIds = remaining;
      return;
    }
    const next = this.selectedIds.slice();
    for (const m of filtered) {
      if (next.indexOf(m.id) < 0) {
        next.push(m.id);
      }
    }
    this.selectedIds = next;
  }

  private toggleSelect(modelId: string): void {
    const idx = this.selectedIds.indexOf(modelId);
    if (idx >= 0) {
      this.selectedIds.splice(idx, 1);
    } else {
      this.selectedIds.push(modelId);
    }
  }

  /** 缺少缩略图且可渲染的模型（横幅计数与生成入参）。 */
  private modelsMissingThumb(): Array<SpineModelItem> {
    const result = new Array<SpineModelItem>();
    for (const m of this.models) {
      if (!m.hasThumb && m.isSupported()) {
        result.push(m);
      }
    }
    return result;
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text($r('app.string.drawer_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme().text)
          .maxLines(1)
          .layoutWeight(1)

        if (!this.importing) {
          Button() {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(18)
              .fontColor([Color.White])
          }
          .width(38)
          .height(38)
          .borderRadius(19)
          .backgroundColor(this.theme().importBtn)
          .padding(0)
          .accessibilityText($r('app.string.import_model'))
          .onClick(() => {
            this.onImport();
          })
        } else {
          Button(this.importProgress.length > 0
            ? $r('app.string.cancel_import_progress', this.importProgress)
            : $r('app.string.btn_cancel_import'))
            .height(38)
            .borderRadius(19)
            .padding({ left: 14, right: 14 })
            .fontSize(13)
            .backgroundColor(this.theme().danger)
            .fontColor(Color.White)
            .onClick(() => {
              this.onImport();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.batchMode) {
        this.BatchToolbar()
      } else if (this.models.length > 0) {
        Row({ space: 8 }) {
          TextInput({ text: this.searchQuery, placeholder: $r('app.string.search_hint') })
            .layoutWeight(1)
            .height(38)
            .fontSize(13)
            .fontColor(this.theme().text)
            .backgroundColor(this.theme().chip)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.searchQuery = value;
            })
          if (this.searchQuery.length > 0) {
            Button() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(14)
                .fontColor([this.theme().textSecondary])
            }
            .width(38)
            .height(38)
            .borderRadius(19)
            .backgroundColor(this.theme().chip)
            .padding(0)
            .accessibilityText($r('app.string.search_clear'))
            .onClick(() => {
              this.searchQuery = '';
            })
          }
          Button() {
            SymbolGlyph(this.allGroupsCollapsed() ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
              .fontSize(16)
              .fontColor([this.theme().textSecondary])
          }
          .width(38)
          .height(38)
          .borderRadius(19)
          .backgroundColor(this.theme().chip)
          .padding(0)
          .accessibilityText(this.allGroupsCollapsed()
            ? $r('app.string.expand_all')
            : $r('app.string.collapse_all'))
          .onClick(() => {
            this.toggleCollapseAll();
          })
          Button($r('app.string.batch_manage'))
            .height(38)
            .borderRadius(19)
            .padding({ left: 14, right: 14 })
            .fontSize(13)
            .backgroundColor(this.theme().chip)
            .fontColor(this.theme().text)
            .onClick(() => {
              this.enterBatch();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      if (!this.batchMode &&
        (this.thumbGenerating || (!this.thumbBannerDismissed && this.modelsMissingThumb().length > 0))) {
        this.ThumbBanner()
      }

      if (this.models.length === 0) {
        this.EmptyGuide()
      } else if (this.searchQuery.trim().length > 0 && this.filteredModels().length === 0) {
        Column() {
          Text($r('app.string.search_empty'))
            .fontSize(14)
            .fontColor(this.theme().textMuted)
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .width('100%')
      } else {
        List({ space: 10 }) {
          ForEach(this.buildGroups(), (group: ModelGroup) => {
            ListItem() {
              Column({ space: 10 }) {
                this.GroupHeader(group)
                if (!this.isCollapsed(group.name) || this.searchQuery.trim().length > 0) {
                  this.ModelPairGrid(group.models)
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
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 100 })
    .backgroundColor(this.theme().pageBg)
  }

  /** 批量模式工具栏：全选 | 已选 n | 删除 | 完成（替换搜索行）。 */
  @Builder
  BatchToolbar() {
    Row({ space: 10 }) {
      Row({ space: 6 }) {
        Checkbox()
          .select(this.isFilteredAllSelected())
          .selectedColor(this.theme().cardSelected)
          .width(20)
          .height(20)
          .hitTestBehavior(HitTestMode.None)
        Text($r('app.string.batch_select_all'))
          .fontSize(13)
          .fontColor(this.theme().textSecondary)
      }
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.toggleSelectAll();
      })

      Text($r('app.string.batch_selected_count', this.selectedIds.length))
        .fontSize(12)
        .fontColor(this.theme().textMuted)
        .maxLines(1)
        .layoutWeight(1)

      Button($r('app.string.batch_delete'))
        .height(34)
        .fontSize(13)
        .padding({ left: 16, right: 16 })
        .backgroundColor(this.theme().danger)
        .fontColor(Color.White)
        .enabled(this.selectedIds.length > 0)
        .opacity(this.selectedIds.length > 0 ? 1 : 0.5)
        .onClick(() => {
          if (this.selectedIds.length === 0) {
            return;
          }
          const ids = this.selectedIds.slice();
          this.getUIContext().showAlertDialog({
            message: $r('app.string.batch_delete_confirm', ids.length),
            primaryButton: {
              value: $r('app.string.dialog_cancel'),
              action: (): void => {
              }
            },
            secondaryButton: {
              value: $r('app.string.dialog_delete'),
              fontColor: this.theme().danger,
              action: (): void => {
                this.exitBatch();
                this.onDeleteModels(ids);
              }
            }
          });
        })

      Button($r('app.string.batch_done'))
        .height(34)
        .fontSize(13)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.theme().chip)
        .fontColor(this.theme().text)
        .onClick(() => {
          this.exitBatch();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 缺图补全横幅：缺 N 个 → 生成/忽略；生成中 → 进度文本。 */
  @Builder
  ThumbBanner() {
    Row({ space: 8 }) {
      if (this.thumbGenerating) {
        Text($r('app.string.thumb_generating', this.thumbGenCurrent, this.thumbGenTotal))
          .fontSize(12)
          .fontColor(this.theme().textSecondary)
          .layoutWeight(1)
          .maxLines(1)
      } else {
        Text($r('app.string.thumb_banner_text', this.modelsMissingThumb().length))
          .fontSize(12)
          .fontColor(this.theme().textSecondary)
          .layoutWeight(1)
          .maxLines(1)
        Button($r('app.string.thumb_banner_generate'))
          .height(28)
          .fontSize(12)
          .padding({ left: 14, right: 14 })
          .backgroundColor(this.theme().importBtn)
          .fontColor(Color.White)
          .onClick(() => {
            const ids = new Array<string>();
            for (const m of this.modelsMissingThumb()) {
              ids.push(m.id);
            }
            this.onGenerateThumbs(ids);
          })
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(12)
            .fontColor([this.theme().textSecondary])
        }
        .width(28)
        .height(28)
        .borderRadius(14)
        .backgroundColor(this.theme().chip)
        .padding(0)
        .accessibilityText($r('app.string.search_clear'))
        .onClick(() => {
          this.thumbBannerDismissed = true;
        })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(10)
    .backgroundColor(this.theme().card)
    .alignItems(VerticalAlign.Center)
  }

  /** 空库三步引导卡：标题 + 三步说明 + 大号导入按钮。 */
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
      SymbolGlyph(this.isCollapsed(group.name) ? $r('sys.symbol.chevron_right') : $r('sys.symbol.chevron_down'))
        .fontSize(12)
        .fontColor([this.theme().textSecondary])
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
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(14)
          .fontColor([this.theme().textSecondary])
          .width(24)
          .bindMenu([
            {
              value: $r('app.string.menu_rename_group'),
              action: (): void => {
                this.onRenameGroup(group.name);
              }
            },
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

  private chunkPairs(models: Array<SpineModelItem>): Array<Array<SpineModelItem>> {
    const pairs = new Array<Array<SpineModelItem>>();
    for (let i = 0; i < models.length; i += 2) {
      const pair = new Array<SpineModelItem>();
      pair.push(models[i]);
      if (i + 1 < models.length) {
        pair.push(models[i + 1]);
      }
      pairs.push(pair);
    }
    return pairs;
  }

  /** 两列卡片：每行两个等宽卡片，奇数行右侧留占位。 */
  @Builder
  ModelPairGrid(models: Array<SpineModelItem>) {
    Column({ space: 10 }) {
      ForEach(this.chunkPairs(models), (pair: Array<SpineModelItem>) => {
        Row({ space: 10 }) {
          Column() {
            this.ModelCard(pair[0])
          }
          .layoutWeight(1)
          if (pair.length > 1) {
            Column() {
              this.ModelCard(pair[1])
            }
            .layoutWeight(1)
          } else {
            Column()
              .layoutWeight(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (pair: Array<SpineModelItem>) => {
        // key 含 hasThumb：缩略图落盘后强制重建卡片项（ForEach 同 key 不重渲染）
        let key = `${pair[0].id}::${pair[0].hasThumb ? 1 : 0}::${pair.length}`;
        if (pair.length > 1) {
          key += `::${pair[1].hasThumb ? 1 : 0}`;
        }
        return key;
      })
    }
    .width('100%')
  }

  /** 卡片缩略图（64x84 圆角 8）：有图显示 file 图，无图占位；批量勾选叠加左上角。 */
  @Builder
  ThumbImage(model: SpineModelItem) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (model.hasThumb) {
        Image(`file://${getContext(this).filesDir}/thumbs/${model.id}.png`)
          .width(64)
          .height(84)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .interpolation(ImageInterpolation.Medium)
      } else {
        Column() {
          SymbolGlyph($r('sys.symbol.person'))
            .fontSize(22)
            .fontColor([this.theme().textMuted])
        }
        .width(64)
        .height(84)
        .borderRadius(8)
        .backgroundColor(this.theme().chip)
        .justifyContent(FlexAlign.Center)
      }
      if (this.batchMode) {
        Checkbox()
          .select(this.isSelected(model.id))
          .selectedColor(this.theme().cardSelected)
          .width(18)
          .height(18)
          .margin(4)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(64)
  }

  @Builder
  ModelCard(model: SpineModelItem) {
    Row({ space: 10 }) {
      this.ThumbImage(model)
      Column({ space: 6 }) {
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
            .flexShrink(1)
            .onClick(() => {
              if (!this.batchMode) {
                this.onMoveToGroup(model.id);
              }
            })
        }
        .alignItems(VerticalAlign.Center)
        if (!this.batchMode) {
          Row({ space: 6 }) {
            Button($r('app.string.set_main_short'))
              .layoutWeight(1)
              .fontSize(12)
              .height(28)
              .backgroundColor(model.id === this.mainModelId ? this.theme().cardSelected : this.theme().chip)
              .fontColor(model.id === this.mainModelId ? Color.White : this.theme().textSecondary)
              .accessibilityText($r('app.string.set_main'))
              .onClick(() => {
                this.onSelectMain(model.id);
              })
            Button($r('app.string.set_sub_short'))
              .layoutWeight(1)
              .fontSize(12)
              .height(28)
              .backgroundColor(model.id === this.subModelId ? this.theme().cardSelected : this.theme().chip)
              .fontColor(model.id === this.subModelId ? Color.White : this.theme().textSecondary)
              .accessibilityText($r('app.string.set_sub'))
              .onClick(() => {
                this.onSelectSub(model.id);
              })
          }
          .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (!this.batchMode) {
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(12)
            .fontColor([this.theme().textSecondary])
        }
        .width(24)
        .height(24)
        .borderRadius(12)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .accessibilityText($r('app.string.a11y_delete_model'))
        .onClick(() => {
          this.onDelete(model.id);
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(12)
    .borderRadius(12)
    .backgroundColor(this.theme().card)
    .border({
      width: 2,
      color: this.batchMode && this.isSelected(model.id) ? this.theme().cardSelected : Color.Transparent
    })
    .onClick(() => {
      if (this.batchMode) {
        this.toggleSelect(model.id);
      }
    })
    .bindContextMenuByResponseType(this.cardMenuItems(model), ResponseType.LongPress)
  }

  /** 长按模型卡片快捷菜单项：设为主/设为副/移动分组/删除（批量模式下返回空数组不弹菜单）。 */
  private cardMenuItems(model: SpineModelItem): Array<MenuElement> {
    if (this.batchMode) {
      return [];
    }
    return [
      {
        value: $r('app.string.set_main'),
        action: (): void => {
          this.onSelectMain(model.id);
        }
      },
      {
        value: $r('app.string.set_sub'),
        action: (): void => {
          this.onSelectSub(model.id);
        }
      },
      {
        value: $r('app.string.menu_move_group'),
        action: (): void => {
          this.onMoveToGroup(model.id);
        }
      },
      {
        value: $r('app.string.dialog_delete'),
        action: (): void => {
          this.onDelete(model.id);
        }
      }
    ];
  }
}
