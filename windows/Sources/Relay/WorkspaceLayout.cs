using System;
using System.Collections.Generic;
using System.Linq;

namespace Relay;

// Account IDs and normalized divider positions survive browser recreation and window resizing.
public sealed class WorkspaceLayout
{
    public List<string> Panes { get; set; } = [];
    public string Arrangement { get; set; } = "grid";
    public double Primary { get; set; } = 0.5;
    public List<double> Cuts { get; set; } = [];
    public static readonly string[] Arrangements = ["columns", "rows", "grid", "main-left", "main-top"];
    public static readonly string[] Labels = ["Side by side", "Stacked", "Grid", "Main on left", "Main on top"];
    public readonly record struct CellRect(double X, double Y, double Width, double Height);
    public readonly record struct Divider(int Index, bool Vertical, double Position, double Start, double Length);

    public void Normalize(IEnumerable<string> available)
    {
        var known = available.ToHashSet(StringComparer.Ordinal);
        Panes = (Panes ?? []).Where(known.Contains).Distinct(StringComparer.Ordinal).Take(4).ToList();
        if (!Arrangements.Contains(Arrangement)) Arrangement = "grid";
        NormalizeSizes();
    }
    private void NormalizeSizes()
    {
        Primary = double.IsFinite(Primary) ? Math.Clamp(Primary, 0.15, 0.85) : 0.5;
        int segments = Arrangement is "columns" or "rows" ? Panes.Count : Arrangement == "grid" ? (Panes.Count > 2 ? 2 : 1) : Math.Max(1, Panes.Count - 1);
        int expected = Math.Max(0, segments - 1);
        if (Cuts == null || Cuts.Count != expected || Cuts.Where((v, i) => !double.IsFinite(v) || v + 0.000000001 < (i == 0 ? 0 : Cuts[i - 1]) + 0.1 || v > 0.9).Any())
            Cuts = Enumerable.Range(1, expected).Select(i => (double)i / segments).ToList();
    }
    public void Select(string id, string? active)
    {
        if (Panes.Contains(id)) return;
        int index = active == null ? -1 : Panes.IndexOf(active);
        if (index < 0 && Panes.Count > 0) index = 0;
        if (index >= 0) Panes[index] = id; else Panes.Add(id);
        NormalizeSizes();
    }
    public bool Add(string id)
    {
        if (Panes.Contains(id) || Panes.Count >= 4) return false;
        Panes.Add(id); NormalizeSizes(); return true;
    }
    public void Remove(string id) { Panes.Remove(id); NormalizeSizes(); }
    private double Edge(int index) => index == 0 ? 0 : index > Cuts.Count ? 1 : Cuts[index - 1];
    public CellRect Cell(int index)
    {
        NormalizeSizes();
        int count = Panes.Count;
        if (count <= 1) return new(0, 0, 1, 1);
        double start = Edge(index), length = Edge(index + 1) - start;
        if (Arrangement == "columns") return new(start, 0, length, 1);
        if (Arrangement == "rows") return new(0, start, 1, length);
        if (Arrangement == "main-left") return index == 0 ? new(0, 0, Primary, 1) : new(Primary, Edge(index - 1), 1 - Primary, Edge(index) - Edge(index - 1));
        if (Arrangement == "main-top") return index == 0 ? new(0, 0, 1, Primary) : new(Edge(index - 1), Primary, Edge(index) - Edge(index - 1), 1 - Primary);
        double y = index < 2 ? 0 : Cuts[0], height = count == 2 ? 1 : index < 2 ? Cuts[0] : 1 - Cuts[0];
        return count == 3 && index == 2 ? new(0, y, 1, height) : new(index % 2 == 0 ? 0 : Primary, y, index % 2 == 0 ? Primary : 1 - Primary, height);
    }
    public List<Divider> Dividers()
    {
        NormalizeSizes();
        if (Panes.Count < 2) return [];
        var result = new List<Divider>();
        if (Arrangement is "columns" or "rows")
            result.AddRange(Cuts.Select((v, i) => new Divider(i, Arrangement == "columns", v, 0, 1)));
        else
        {
            bool vertical = Arrangement != "main-top";
            result.Add(new(-1, vertical, Primary, 0, Arrangement == "grid" && Panes.Count == 3 ? Cuts[0] : 1));
            result.AddRange(Cuts.Select((v, i) => new Divider(i, !vertical, v, Arrangement == "grid" ? 0 : Primary, Arrangement == "grid" ? 1 : 1 - Primary)));
        }
        return result;
    }
    public void Resize(int divider, double position)
    {
        NormalizeSizes();
        if (!double.IsFinite(position)) return;
        if (divider == -1) Primary = Math.Clamp(position, 0.15, 0.85);
        else if (divider >= 0 && divider < Cuts.Count) Cuts[divider] = Math.Clamp(position, Edge(divider) + 0.1, Edge(divider + 2) - 0.1);
    }
}
