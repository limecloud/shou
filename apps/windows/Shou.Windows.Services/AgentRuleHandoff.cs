namespace Shou.Windows.Services;

/// <summary>Builds a local handoff; paths remain data and no agent is launched.</summary>
public static class AgentRuleHandoff
{
    public static string Create(string skillEntrypoint, string executable, string? directory)
    {
        var scope = string.IsNullOrWhiteSpace(directory)
            ? T("先查看常用位置、开发项目和现有规则，再定位尚未覆盖的占用大头。")
            : F("请分析这个目录并制定规则：{0}", directory);
        return F("请阅读本地 Shou Skill：{0}\n使用 Shou CLI：{1}\n{2}\n\n请按 Skill 分析主要占用，调查到具体用途，并说明尚未解决的大项及下一步。按用途、重建代价和保留条件拆分可独立选择的规则。每条分别校验、导入为停用草稿并预览，说明命中、保护项和新增收益。只追问证据不能回答的用途、活跃项目与保留要求。由我逐条决定后，回到 Shou“规则与排除”启用所选规则并重新扫描，再确认实际删除。已有明确授权可继续，未有回执不得称已清理；执行后核验逐项结果与剩余占用。", skillEntrypoint, executable, scope);
    }
}
