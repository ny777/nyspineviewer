/**
 * 模型库列表数据源：LazyForEach 扁平行数据（分组头行 + 一行两卡行）。
 * 任何库状态变更都走全量 rebuild → onDataReloaded，LazyForEach 按 key 差分只重建变化的行，
 * 行 key 携带该行渲染所需的全部可变状态（名称/版本/格式/分组/缩略图/勾选/主副/批量位）。
 */
import { SpineModelItem } from '../model/SpineModelItem';

/** 页面渲染用分组视图（'' = 未分组，置顶）。 */
export class ModelGroup {
  name: string;
  models: Array<SpineModelItem>;

  constructor(name: string, models: Array<SpineModelItem>) {
    this.name = name;
    this.models = models;
  }
}

/** 模型库列表中的一行：分组头（isHeader=true）或一行两卡（items 含 1~2 个模型）。 */
export class LibRow {
  /** 行唯一 key：变更即整行重建，不变则 LazyForEach 复用原组件。 */
  readonly key: string;
  readonly isHeader: boolean;
  /** 分组头名称（'' = 未分组；非头行为空串）。 */
  readonly headerName: string;
  /** 分组头内模型数（非头行为 0）。 */
  readonly headerCount: number;
  /** 配对行模型（长度 1~2；头行为空数组）。 */
  readonly items: Array<SpineModelItem>;

  constructor(key: string, isHeader: boolean, headerName: string, headerCount: number,
    items: Array<SpineModelItem>) {
    this.key = key;
    this.isHeader = isHeader;
    this.headerName = headerName;
    this.headerCount = headerCount;
    this.items = items;
  }
}

/**
 * 模型库 LazyForEach 数据源：持扁平行数组，rebuild 全量重算后通知刷新。
 * LazyForEach 不观察 @State/@Prop，页面侧所有相关状态变更必须显式触发 rebuild。
 */
export class LibraryListDataSource implements IDataSource {
  private rows: Array<LibRow> = [];
  private listeners: Array<DataChangeListener> = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): LibRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  /**
   * 由分组视图重建扁平行列表并通知 LazyForEach 重新差分：
   * 搜索激活时折叠组仍展开卡片（与旧实现一致）；行 key 含全部行内可变状态。
   */
  rebuild(groups: Array<ModelGroup>, collapsedGroups: Array<string>, searchActive: boolean,
    selectedIds: Array<string>, mainModelId: string, subModelId: string, batchMode: boolean): void {
    const collapsed = new Set<string>(collapsedGroups);
    const selected = new Set<string>(selectedIds);
    const rows = new Array<LibRow>();
    for (const group of groups) {
      const groupCollapsed = !searchActive && collapsed.has(group.name);
      rows.push(new LibRow(`h:${group.name}:${group.models.length}:${collapsed.has(group.name) ? 1 : 0}`,
        true, group.name, group.models.length, new Array<SpineModelItem>()));
      if (groupCollapsed) {
        continue;
      }
      for (let i = 0; i < group.models.length; i += 2) {
        const items = new Array<SpineModelItem>();
        items.push(group.models[i]);
        if (i + 1 < group.models.length) {
          items.push(group.models[i + 1]);
        }
        rows.push(new LibRow(this.pairKey(items, selected, mainModelId, subModelId, batchMode),
          false, '', 0, items));
      }
    }
    this.rows = rows;
    this.notifyReload();
  }

  /** 配对行 key：批量位 + 每模型的 名称/版本/格式/分组/缩略图/勾选/主/副 状态位。 */
  private pairKey(items: Array<SpineModelItem>, selected: Set<string>, mainModelId: string,
    subModelId: string, batchMode: boolean): string {
    let key = `p:${batchMode ? 1 : 0}`;
    for (const m of items) {
      key += `:${m.id}:${m.name}:${m.version}:${m.format}:${m.group}:${m.hasThumb ? 1 : 0}` +
        `:${selected.has(m.id) ? 1 : 0}:${m.id === mainModelId ? 1 : 0}:${m.id === subModelId ? 1 : 0}`;
    }
    return key;
  }

  private notifyReload(): void {
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}
