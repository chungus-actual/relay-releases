using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace Relay;

// Runtime sessions belong to an account, never to the service catalogue or saved layouts.
internal sealed class TerminalWorkspace : IDisposable
{
    internal readonly List<TerminalTab> Tabs = [];
    internal string? ActiveTab;
    private int nextTab = 1;
    internal TerminalTab? Current => Tabs.Find(t => t.Id == ActiveTab);
    internal TerminalTab AddTab() {
        var tab = new TerminalTab { Name = "Session " + nextTab++ };
        Tabs.Add(tab); ActiveTab = tab.Id; return tab;
    }
    internal void CloseTab(TerminalTab tab) {
        int index = Tabs.IndexOf(tab);
        if (index < 0) return;
        Tabs.RemoveAt(index); tab.Dispose();
        if (ActiveTab == tab.Id) ActiveTab = Tabs.Count == 0 ? null : Tabs[Math.Min(index, Tabs.Count - 1)].Id;
    }
    public void Dispose() { foreach (var tab in Tabs) tab.Dispose(); Tabs.Clear(); ActiveTab = null; }
}

internal sealed class TerminalTab : IDisposable
{
    internal readonly string Id = Guid.NewGuid().ToString("N");
    internal string Name = "";
    internal readonly List<TerminalPane> Panes = [];
    internal string? ActivePane;
    internal TerminalSplit? Layout;
    internal bool Zoomed;
    private int nextPane = 1;
    internal TerminalPane AddPane(string? beside = null, string direction = "columns") {
        var pane = new TerminalPane { Name = "Shell " + nextPane++ };
        if (Layout == null) Layout = new TerminalSplit { Pane = pane.Id };
        else if (Layout.FindPane(beside ?? ActivePane) is { } leaf) {
            leaf.First = new TerminalSplit { Pane = leaf.Pane };
            leaf.Second = new TerminalSplit { Pane = pane.Id };
            leaf.Pane = null; leaf.Direction = direction; leaf.Ratio = 0.5;
        } else throw new InvalidOperationException("The terminal pane is no longer open.");
        Panes.Add(pane); ActivePane = pane.Id; Zoomed = false; return pane;
    }
    internal void ClosePane(TerminalPane pane) {
        int index = Panes.IndexOf(pane);
        if (index < 0) return;
        Panes.RemoveAt(index); pane.Dispose(); Layout = Layout?.Remove(pane.Id);
        if (ActivePane == pane.Id) ActivePane = Panes.Count == 0 ? null : Panes[Math.Min(index, Panes.Count - 1)].Id;
        if (Panes.Count < 2) Zoomed = false;
    }
    public void Dispose() { foreach (var pane in Panes) pane.Dispose(); Panes.Clear(); Layout = null; ActivePane = null; }
}

internal sealed class TerminalPane : IDisposable
{
    internal readonly string Id = Guid.NewGuid().ToString("N");
    internal string Name = "", Status = "Starting…";
    internal short Columns = 80, Rows = 24;
    internal PseudoTerminal? Process;
    internal readonly StringBuilder History = new();
    internal void Remember(string text) {
        History.Append(text);
        if (History.Length > 262144) History.Remove(0, History.Length - 262144);
    }
    public void Dispose() { Process?.Dispose(); Process = null; History.Clear(); }
}

internal sealed class TerminalSplit
{
    public string Id { get; } = Guid.NewGuid().ToString("N");
    public string? Pane { get; set; }
    public string Direction { get; set; } = "columns";
    public double Ratio { get; set; } = 0.5;
    public TerminalSplit? First { get; set; }
    public TerminalSplit? Second { get; set; }
    internal TerminalSplit? FindPane(string? id) => Pane == id && id != null ? this : First?.FindPane(id) ?? Second?.FindPane(id);
    internal TerminalSplit? Find(string? id) => Id == id ? this : First?.Find(id) ?? Second?.Find(id);
    internal TerminalSplit? Remove(string id) {
        if (Pane != null) return Pane == id ? null : this;
        First = First?.Remove(id); Second = Second?.Remove(id);
        return First == null ? Second : Second == null ? First : this;
    }
}
