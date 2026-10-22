using AppManager;

private delegate bool Check();

private void wait_until(Check check) {
    var deadline = get_monotonic_time() + 3 * TimeSpan.SECOND;
    while (!check() && get_monotonic_time() < deadline) {
        while (MainContext.default().iteration(false)) {}
        Thread.usleep(1000);
    }
    assert_true(check());
}

private void collect_widgets(Gtk.Widget parent, Gee.ArrayList<Gtk.Widget> widgets) {
    widgets.add(parent);
    for (var child = parent.get_first_child(); child != null; child = child.get_next_sibling()) {
        collect_widgets(child, widgets);
    }
}

private class Editor : Object {
    public EnvVarsGroup group;
    public Gtk.Window window;
    public string[] saved = {};
    private string[] current;

    public Editor(string[] env_vars) {
        group = new EnvVarsGroup(env_vars);
        current = env_vars;
        group.changed.connect((editor) => { current = editor.get_env_vars(); });
        group.committed.connect(() => { saved = current; });
        window = new Gtk.Window();
        window.set_child(group);
        window.present();
    }

    public Gtk.Entry entry(int index) {
        var widgets = new Gee.ArrayList<Gtk.Widget>();
        collect_widgets(group, widgets);
        foreach (var widget in widgets) {
            if (widget is Gtk.Entry && index-- == 0) return (Gtk.Entry) widget;
        }
        assert_not_reached();
    }

    public Gtk.Button button(string icon) {
        var widgets = new Gee.ArrayList<Gtk.Widget>();
        collect_widgets(group, widgets);
        foreach (var widget in widgets) {
            var button = widget as Gtk.Button;
            if (button != null && button.icon_name == icon) return button;
        }
        assert_not_reached();
    }

    public void paste(int index, string text) {
        var target = entry(index);
        target.grab_focus();
        target.get_clipboard().set_text(text);
        ((Gtk.Text) target.get_delegate()).paste_clipboard();
    }
}

private void test_clipboard_assignment() {
    var editor = new Editor({});
    editor.button("list-add-symbolic").clicked();
    editor.paste(0, "QT_QPA_PLATFORM=xcb");
    wait_until(() => editor.saved.length == 1);
    assert_cmpstr(editor.entry(0).text, CompareOperator.EQ, "QT_QPA_PLATFORM");
    assert_cmpstr(editor.entry(1).text, CompareOperator.EQ, "xcb");
    assert_cmpstr(editor.saved[0], CompareOperator.EQ, "QT_QPA_PLATFORM=xcb");
    editor.window.destroy();
}

private void test_value_paste_is_literal() {
    var editor = new Editor({ "HTTP_PROXY=old" });
    editor.entry(1).select_region(0, -1);
    editor.paste(1, "http://localhost:8080/?mode=direct");
    wait_until(() => editor.entry(1).text == "http://localhost:8080/?mode=direct");
    assert_cmpstr(editor.entry(0).text, CompareOperator.EQ, "HTTP_PROXY");
    editor.entry(1).activate();
    assert_cmpstr(editor.saved[0], CompareOperator.EQ, "HTTP_PROXY=http://localhost:8080/?mode=direct");
    editor.entry(1).select_region(0, -1);
    editor.paste(1, "QT_QPA_PLATFORM=xcb");
    wait_until(() => editor.entry(1).text == "QT_QPA_PLATFORM=xcb");
    assert_cmpstr(editor.entry(0).text, CompareOperator.EQ, "HTTP_PROXY");
    editor.window.destroy();
}

private void test_typing_and_plain_paste() {
    var editor = new Editor({});
    editor.button("list-add-symbolic").clicked();
    editor.paste(0, "QT_QPA_PLATFORM");
    wait_until(() => editor.entry(0).text == "QT_QPA_PLATFORM");
    int position = editor.entry(0).text.char_count();
    editor.entry(0).get_delegate().insert_text("=", 1, ref position);
    assert_cmpstr(editor.entry(0).text, CompareOperator.EQ, "QT_QPA_PLATFORM=");
    assert_cmpstr(editor.entry(1).text, CompareOperator.EQ, "");
    editor.window.destroy();
}

private void test_multiline_replacement_and_limit() {
    var editor = new Editor({ "KEEP=1", "REPLACE=old" });
    editor.entry(2).select_region(1, 3);
    editor.paste(2, "QT_QPA_PLATFORM=xcb\nGDK_BACKEND=x11\nLIBGL_ALWAYS_SOFTWARE=1\nHTTP_PROXY=http://localhost:8080\nEXTRA=dropped");
    wait_until(() => editor.group.get_env_vars().length == 5);
    var actual = editor.group.get_env_vars();
    assert_cmpstr(actual[0], CompareOperator.EQ, "KEEP=1");
    assert_cmpstr(actual[1], CompareOperator.EQ, "QT_QPA_PLATFORM=xcb");
    assert_cmpstr(actual[2], CompareOperator.EQ, "GDK_BACKEND=x11");
    assert_cmpstr(actual[3], CompareOperator.EQ, "LIBGL_ALWAYS_SOFTWARE=1");
    assert_cmpstr(actual[4], CompareOperator.EQ, "HTTP_PROXY=http://localhost:8080");
    assert_false(editor.button("list-add-symbolic").sensitive);
    editor.paste(2, "QT_QPA_PLATFORM=wayland\nEXTRA=dropped");
    wait_until(() => editor.entry(3).text == "wayland");
    assert_cmpint(editor.group.get_env_vars().length, CompareOperator.EQ, 5);
    editor.button("user-trash-symbolic").clicked();
    assert_true(editor.button("list-add-symbolic").sensitive);
    assert_cmpint(editor.saved.length, CompareOperator.EQ, 4);
    editor.window.destroy();
}

private void test_invalid_paste_preserves_row() {
    var editor = new Editor({ "QT_QPA_PLATFORM=xcb" });
    int position = 3;
    editor.entry(0).get_delegate().insert_text("=1", 2, ref position);
    assert_cmpstr(editor.entry(0).text, CompareOperator.EQ, "QT_QPA_PLATFORM");
    assert_cmpstr(editor.entry(1).text, CompareOperator.EQ, "xcb");
    editor.window.destroy();
}

private void test_invalid_clipboard_preserves_selection() {
    var editor = new Editor({ "QT_QPA_PLATFORM=xcb" });
    bool edited = false;
    editor.entry(0).changed.connect(() => { edited = true; });
    editor.entry(0).select_region(0, -1);
    editor.paste(0, "=1");
    wait_until(() => edited);
    assert_cmpstr(editor.entry(0).text, CompareOperator.EQ, "QT_QPA_PLATFORM");
    assert_cmpstr(editor.entry(1).text, CompareOperator.EQ, "xcb");
    editor.window.destroy();
}

private void test_editor_is_released() {
    var editor = new Editor({ "QT_QPA_PLATFORM=xcb" });
    var group = WeakRef(editor.group);
    editor.window.destroy();
    editor = null;
    wait_until(() => group.get() == null);
}

private void test_unicode_name_limit_and_reopen() {
    var editor = new Editor({});
    editor.button("list-add-symbolic").clicked();
    editor.paste(0, "APP_CONFIG_DIR=\"/home/alex/日本語 config\"\n" + string.nfill(70, 'A') + "=1");
    wait_until(() => editor.saved.length == 2);
    assert_cmpstr(editor.entry(1).text, CompareOperator.EQ, "/home/alex/日本語 config");
    assert_cmpint(editor.entry(2).text.char_count(), CompareOperator.EQ, 64);
    editor.entry(1).grab_focus();
    int position = editor.entry(1).text.char_count();
    editor.entry(1).get_delegate().insert_text("/data", -1, ref position);
    editor.entry(0).grab_focus();
    wait_until(() => editor.saved[0] == "APP_CONFIG_DIR=/home/alex/日本語 config/data");
    var reopened = new Editor(editor.saved);
    assert_cmpstr(reopened.entry(1).text, CompareOperator.EQ, "/home/alex/日本語 config/data");
    reopened.window.destroy();
    editor.window.destroy();
}

int main(string[] args) {
    Test.init(ref args);
    if (!Gtk.init_check()) return 77;
    Adw.init();
    Test.add_func("/env-vars-group/clipboard-assignment", test_clipboard_assignment);
    Test.add_func("/env-vars-group/value-paste-is-literal", test_value_paste_is_literal);
    Test.add_func("/env-vars-group/typing-and-plain-paste", test_typing_and_plain_paste);
    Test.add_func("/env-vars-group/multiline-replacement-and-limit", test_multiline_replacement_and_limit);
    Test.add_func("/env-vars-group/invalid-paste-preserves-row", test_invalid_paste_preserves_row);
    Test.add_func("/env-vars-group/invalid-clipboard-preserves-selection", test_invalid_clipboard_preserves_selection);
    Test.add_func("/env-vars-group/editor-is-released", test_editor_is_released);
    Test.add_func("/env-vars-group/unicode-name-limit-and-reopen", test_unicode_name_limit_and_reopen);
    return Test.run();
}
