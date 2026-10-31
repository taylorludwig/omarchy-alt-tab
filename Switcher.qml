import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons // qmllint disable import
import qs.Ui // qmllint disable import
import "SettingsModel.js" as SettingsModel
import "WindowList.js" as WindowList

// Omarchy Alt-Tab service. Hyprland drives it with custom events from
// hypr/omarchy-alt-tab.lua: "open;<next|prev>;<snapshot>", then next / prev / up /
// down / scope while the modifier is held, and commit or cancel at the end.
// The overlay never takes keyboard focus, so the focused app is untouched
// until the switch actually happens.
Item {
    id: root

    property var shell: null
    property var manifest: null
    readonly property string pluginId: String((root.manifest && root.manifest.id) || "io.github.jburchel.omarchy-alt-tab")

    SettingsStore {
        id: store
        shell: root.shell
        pluginId: root.pluginId
    }

    // One switcher session, from MOD+TAB press to MOD release.
    property bool active: false
    property bool shown: false
    property var snapshot: ({ workspaceId: NaN, monitor: "", active: "", windows: [] })
    property string scope: "all"
    property var windows: []
    property int selectedIndex: -1
    // Whether the last session ever put the switcher on screen (quick taps
    // should not). Reported by the `state` IPC call for tests.
    property bool lastSessionShown: false

    onShownChanged: if (root.shown) root.lastSessionShown = true

    readonly property var targetScreen: {
        var screens = Quickshell.screens;
        for (var i = 0; i < screens.length; i++)
            if (screens[i].name === root.snapshot.monitor)
                return screens[i];
        return screens.length > 0 ? screens[0] : null;
    }

    function handle(message) {
        if (message.indexOf("open;") === 0) {
            var rest = message.slice(5);
            var cut = rest.indexOf(";");
            root.start(cut < 0 ? rest : rest.slice(0, cut), cut < 0 ? "" : rest.slice(cut + 1));
            return;
        }
        if (!root.active)
            return;
        if (message === "next")
            root.move(1);
        else if (message === "prev")
            root.move(-1);
        else if (message === "down")
            root.move(cardGrid.columns);
        else if (message === "up")
            root.move(-cardGrid.columns);
        else if (message === "scope")
            root.cycleScope();
        else if (message === "commit")
            root.commit();
        else if (message === "cancel")
            root.finish();
    }

    function start(direction, snapshotText) {
        Hyprland.refreshToplevels();
        root.iconCache = {};
        root.pruneThumbs();
        root.snapshot = WindowList.parseSnapshot(snapshotText);
        root.scope = store.values.scope;
        root.windows = root.filtered();
        root.selectedIndex = WindowList.initialIndex(root.windows, root.snapshot.active, direction);
        root.lastSessionShown = false;
        root.active = true;
        if (store.values.showDelay <= 0)
            root.shown = true;
        else
            showTimer.restart();
    }

    // Snapshot windows in scope that still exist (a window can close while
    // the switcher is up; one that just opened appears once Quickshell sees it).
    function filtered() {
        var existing = {};
        var toplevels = Hyprland.toplevels.values;
        for (var i = 0; i < toplevels.length; i++)
            existing[WindowList.normalizeAddress(toplevels[i].address)] = true;
        var inScope = WindowList.filterWindows(root.snapshot.windows, root.scope, root.snapshot, store.values.includeSpecial);
        return inScope.filter(function(w) { return existing[w.address] === true; });
    }

    // Recompute the list, keeping the selected window selected if it is still
    // there, otherwise the same position.
    function rebuild() {
        var selected = root.windows[root.selectedIndex];
        var index = root.selectedIndex;
        root.windows = root.filtered();
        var kept = selected ? WindowList.indexOfAddress(root.windows, selected.address) : -1;
        root.selectedIndex = kept >= 0 ? kept : Math.min(Math.max(index, 0), root.windows.length - 1);
    }

    function move(delta) {
        if (root.windows.length === 0)
            return;
        root.selectedIndex = WindowList.step(root.selectedIndex, root.windows.length, delta);
        // Stepping means the user is browsing; show the switcher now.
        root.shown = true;
    }

    // Changes scope for this session only; the saved default stays put.
    function cycleScope() {
        var selected = root.windows[root.selectedIndex];
        root.scope = WindowList.nextScope(root.scope);
        root.windows = root.filtered();
        var kept = selected ? WindowList.indexOfAddress(root.windows, selected.address) : -1;
        root.selectedIndex = kept >= 0 ? kept : WindowList.initialIndex(root.windows, root.snapshot.active, "next");
        root.shown = true;
    }

    Connections {
        target: Hyprland.toplevels
        function onValuesChanged() { if (root.active) root.rebuild(); }
    }

    function commit() {
        var target = root.windows[root.selectedIndex];
        root.finish();
        if (target && target.address !== root.snapshot.active)
            root.focusWindow(target.address);
    }

    function commitIndex(index) {
        root.selectedIndex = index;
        root.commit();
        // A click ends the session from our side; leave the submap too.
        Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.submap(\"reset\")"]);
    }

    function finish() {
        showTimer.stop();
        root.active = false;
        root.shown = false;
    }

    // Focusing by address switches to the window's workspace (and opens a
    // special workspace if needed), keeping the tiled layout as it is.
    function focusWindow(address) {
        if (!/^0x[0-9a-f]+$/.test(address))
            return;
        Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ window = \"address:" + address + "\" })"]);
    }

    function toplevelFor(address) {
        var toplevels = Hyprland.toplevels.values;
        for (var i = 0; i < toplevels.length; i++)
            if (WindowList.normalizeAddress(toplevels[i].address) === address)
                return toplevels[i];
        return null;
    }

    property var iconCache: ({})

    // Saved window pictures by address (grabToImage results; keeping the
    // result object keeps its url valid). Bumping thumbRevision re-reads them.
    property var thumbCache: ({})
    property int thumbRevision: 0

    function storeThumb(address, result) {
        if (!address || !result) return;
        root.thumbCache[address] = result;
        root.thumbRevision++;
    }

    function thumbFor(address) {
        var r = root.thumbCache[address];
        return r ? String(r.url) : "";
    }

    function pruneThumbs() {
        var existing = {};
        var toplevels = Hyprland.toplevels.values;
        for (var i = 0; i < toplevels.length; i++)
            existing[WindowList.normalizeAddress(toplevels[i].address)] = true;
        for (var key in root.thumbCache)
            if (existing[key] !== true) delete root.thumbCache[key];
    }

    // Background snapshots. Hyprland only copies windows that are on screen,
    // so the switcher alone can't picture a window on another workspace or
    // scrolled away. Instead, picture the focused window shortly after it gets
    // focus and once more as it loses it. Windows on screen that have no
    // picture yet (after a shell start or workspace switch) get one too.
    // A capture that gets no frame (window already hidden) keeps the old one.
    property string focusedAddress: ""
    property var captureQueue: []
    property string capturing: ""

    function queueCapture(address) {
        if (!store.values.previews || !address || root.captureQueue.indexOf(address) !== -1)
            return;
        root.captureQueue.push(address);
        if (!root.capturing)
            root.nextCapture();
    }

    function nextCapture() {
        grabView.captureSource = null;
        root.capturing = "";
        while (root.captureQueue.length > 0) {
            var address = root.captureQueue.shift();
            var top = root.toplevelFor(address);
            if (top && top.wayland) {
                root.capturing = address;
                grabView.captureSource = top.wayland;
                captureTimeout.restart();
                return;
            }
        }
    }

    function fillMissing() {
        var shown = {};
        var monitors = Hyprland.monitors.values;
        for (var i = 0; i < monitors.length; i++)
            if (monitors[i].activeWorkspace)
                shown[monitors[i].activeWorkspace.id] = true;
        var toplevels = Hyprland.toplevels.values;
        for (var j = 0; j < toplevels.length; j++) {
            var address = WindowList.normalizeAddress(toplevels[j].address);
            if (toplevels[j].workspace && shown[toplevels[j].workspace.id] && !root.thumbCache[address])
                root.queueCapture(address);
        }
    }

    function onFocusChanged(address) {
        if (address === root.focusedAddress)
            return;
        var previous = root.focusedAddress;
        root.focusedAddress = address;
        if (previous)
            root.queueCapture(previous);
        if (address)
            focusCapture.restart();
        else
            focusCapture.stop();
    }

    Timer {
        id: focusCapture
        interval: 700
        onTriggered: root.queueCapture(root.focusedAddress)
    }
    Timer {
        id: fillTimer
        interval: 700
        onTriggered: root.fillMissing()
    }
    // Give up on a window that sends no frame.
    Timer {
        id: captureTimeout
        interval: 1500
        onTriggered: root.nextCapture()
    }
    // Let the frame reach the scene graph before grabbing it.
    Timer {
        id: grabDelay
        interval: 100
        onTriggered: {
            var address = root.capturing;
            if (!address || !grabView.hasContent) {
                root.nextCapture();
                return;
            }
            captureTimeout.stop();
            grabView.grabToImage(function(result) {
                root.storeThumb(address, result);
                root.nextCapture();
            }, Qt.size(grabView.width, grabView.height));
        }
    }

    // Capture surface: a 1x1 transparent overlay that takes no input. The view
    // sits just outside it, so nothing shows on screen, but grabToImage still
    // renders all of it.
    PanelWindow { // qmllint disable uncreatable-type
        id: grabber
        visible: store.values.previews
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omarchy-alt-tab-capture"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        anchors.top: true
        anchors.left: true
        implicitWidth: 1
        implicitHeight: 1
        mask: Region {}

        ScreencopyView {
            id: grabView
            readonly property real sourceAspect: sourceSize.width > 0 && sourceSize.height > 0
                ? sourceSize.width / sourceSize.height : panel.baseCardWidth / panel.baseCardHeight
            readonly property real boxAspect: panel.baseCardWidth / panel.baseCardHeight
            x: 1
            width: sourceAspect >= boxAspect ? panel.baseCardWidth : Math.round(panel.baseCardHeight * sourceAspect)
            height: sourceAspect >= boxAspect ? Math.round(panel.baseCardWidth / sourceAspect) : panel.baseCardHeight
            constraintSize: Qt.size(panel.baseCardWidth * 2, panel.baseCardHeight * 2)
            live: false
            paintCursor: false
            onHasContentChanged: if (hasContent && root.capturing) grabDelay.restart()
        }
    }

    // Hyprland.activeToplevel stays empty until the first focus event, so ask
    // Hyprland which window has focus at startup.
    Process {
        running: true
        command: ["hyprctl", "activewindow", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    if (!root.focusedAddress)
                        root.onFocusChanged(WindowList.normalizeAddress(JSON.parse(text).address));
                } catch (e) {}
                fillTimer.restart();
            }
        }
    }

    function iconFor(toplevel) {
        var ipc = toplevel && toplevel.lastIpcObject ? toplevel.lastIpcObject : {};
        var appId = String((toplevel && toplevel.wayland && toplevel.wayland.appId) || ipc.class || ipc.initialClass || "");
        if (Object.prototype.hasOwnProperty.call(root.iconCache, appId))
            return root.iconCache[appId];
        var entry = root.desktopEntryFor(appId);
        var icon = entry && entry.icon ? String(entry.icon) : appId;
        var library = root.shell && root.shell.appLibrary ? root.shell.appLibrary : null;
        var source = library && typeof library.iconSource === "function" ? String(library.iconSource(icon) || "") : "";
        source = source || Quickshell.iconPath(icon || "application-x-executable", "application-x-executable");
        root.iconCache[appId] = source;
        return source;
    }

    function desktopEntryFor(appId) {
        if (!appId)
            return null;
        if (appId.indexOf("chrome-") === 0) {
            var entries = DesktopEntries.applications.values;
            var best = null;
            var bestScore = 0;
            for (var i = 0; i < entries.length; i++) {
                var score = WindowList.webappMatch(appId, entries[i].execString);
                if (score > bestScore) {
                    best = entries[i];
                    bestScore = score;
                }
            }
            if (best)
                return best;
        }
        return DesktopEntries.heuristicLookup(appId);
    }

    function workspaceLabel(win) {
        if (WindowList.isSpecialWorkspace(win.workspaceId)) {
            var top = root.toplevelFor(win.address);
            var name = top && top.workspace ? String(top.workspace.name || "") : "";
            return name.indexOf("special:") === 0 ? name.slice(8) || "S" : "S";
        }
        return isFinite(win.workspaceId) ? String(win.workspaceId) : "";
    }

    Timer {
        id: showTimer
        interval: Math.max(1, store.values.showDelay)
        onTriggered: if (root.active) root.shown = true
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (!event)
                return;
            if (event.name === "activewindowv2") {
                root.onFocusChanged(WindowList.normalizeAddress(event.data));
                return;
            }
            if (event.name === "workspacev2") {
                fillTimer.restart();
                return;
            }
            if (event.name === "closewindow") {
                delete root.thumbCache[WindowList.normalizeAddress(event.data)];
                return;
            }
            if (event.name !== "custom")
                return;
            var data = String(event.data || "");
            var prefix = "omarchy-alt-tab:";
            if (data.indexOf(prefix) === 0)
                root.handle(data.slice(prefix.length));
        }
    }

    IpcHandler {
        target: "omarchy-alt-tab"
        function settings(): string {
            return root.shell && root.shell.toggle(root.pluginId, "{}") ? "ok" : "unavailable";
        }
        function scope(value: string): string {
            if (WindowList.SCOPES.indexOf(value) === -1)
                return "expected all, workspace or monitor";
            store.set("scope", value);
            return value;
        }
        function showDelay(ms: int): string {
            store.set("showDelay", Math.max(0, Math.min(1000, ms)));
            return String(store.values.showDelay);
        }
        function previews(value: string): string {
            store.set("previews", value === "on");
            return value === "on" ? "on" : "off";
        }
        function workspaceBadges(value: string): string {
            store.set("workspaceBadges", value === "on");
            return value === "on" ? "on" : "off";
        }
        function includeSpecial(value: string): string {
            store.set("includeSpecial", value === "on");
            return value === "on" ? "on" : "off";
        }
        function status(): string {
            return JSON.stringify(store.values);
        }
        // Live session state, for scripts and tests.
        function state(): string {
            var selected = root.windows[root.selectedIndex];
            return JSON.stringify({
                active: root.active,
                shown: root.shown,
                lastSessionShown: root.lastSessionShown,
                scope: root.scope,
                screen: root.targetScreen ? String(root.targetScreen.name) : "",
                columns: cardGrid.columns,
                selectedIndex: root.selectedIndex,
                selected: selected ? selected.address : "",
                windows: root.windows.map(function(w) { return w.address; }),
                saved: Object.keys(root.thumbCache),
                focused: root.focusedAddress
            });
        }
    }

    PanelWindow { // qmllint disable uncreatable-type
        id: panel
        visible: root.shown
        screen: root.targetScreen
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omarchy-alt-tab"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        implicitWidth: frame.width
        implicitHeight: frame.height

        readonly property bool previews: store.values.previews
        readonly property int gap: Style.spacing.xxl
        readonly property int pad: Style.spacing.panelPadding
        readonly property int baseCardWidth: previews ? Style.space(455) : Style.space(128)
        readonly property int baseCardHeight: previews ? Style.space(350) : Style.space(138)
        readonly property int screenWidth: root.targetScreen ? root.targetScreen.width : 1920
        readonly property int screenHeight: root.targetScreen ? root.targetScreen.height : 1080
        readonly property var fit: WindowList.layout(
            Math.max(1, root.windows.length),
            screenWidth * 0.9 - pad * 2,
            screenHeight * 0.8 - pad * 2 - header.height - Style.spacing.lg,
            baseCardWidth, baseCardHeight, gap, 0.4)

        BorderSurface {
            id: frame
            width: content.implicitWidth + frame.contentLeftInset + frame.contentRightInset
            height: content.implicitHeight + frame.contentTopInset + frame.contentBottomInset
            radius: Style.cornerRadius
            color: Color.menu.background
            borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
            padding: panel.pad

            Column {
                id: content
                x: frame.contentLeftInset
                y: frame.contentTopInset
                spacing: Style.spacing.lg

                Item {
                    id: header
                    width: Math.max(implicitWidth, cardGrid.implicitWidth)
                    height: scopeLabel.implicitHeight
                    implicitWidth: scopeLabel.implicitWidth + hint.implicitWidth + Style.spacing.huge

                    Text {
                        textFormat: Text.PlainText
                        id: scopeLabel
                        anchors.left: parent.left
                        text: SettingsModel.scopeLabel(root.scope)
                        color: Color.menu.text
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                    }
                    Text {
                        textFormat: Text.PlainText
                        id: hint
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "`  scope    ·    esc  cancel"
                        color: Color.menu.text
                        opacity: 0.5
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.caption
                    }
                }

                Grid {
                    id: cardGrid
                    visible: root.windows.length > 0
                    columns: panel.fit.cols
                    spacing: panel.gap

                    Repeater {
                        model: root.windows

                        SwitcherCard {
                            required property var modelData
                            required property int index
                            toplevel: root.toplevelFor(modelData.address)
                            iconSource: root.iconFor(toplevel)
                            workspace: store.values.workspaceBadges && root.scope !== "workspace" ? root.workspaceLabel(modelData) : ""
                            selected: index === root.selectedIndex
                            previews: panel.previews
                            live: root.shown
                            cachedSource: root.thumbRevision >= 0 ? root.thumbFor(modelData.address) : ""
                            onThumbnailReady: result => root.storeThumb(modelData.address, result)
                            width: Math.round(panel.baseCardWidth * panel.fit.scale)
                            height: Math.round(panel.baseCardHeight * panel.fit.scale)
                            onHovered: root.selectedIndex = index
                            onClicked: root.commitIndex(index)
                        }
                    }
                }

                Text {
                    textFormat: Text.PlainText
                    visible: root.windows.length === 0
                    text: "No windows here"
                    color: Color.menu.text
                    opacity: 0.7
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.body
                }
            }
        }
    }
}
