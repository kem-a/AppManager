using AppManager.Core;
using AppManager.Utils;

namespace AppManager {
    /** Review a source-only listing; GitHub is the persistent submission history. */
    public class AppHubSubmissionPage : Adw.NavigationPage {
        private Adw.EntryRow id_row;
        private Adw.EntryRow slug_row;
        private Adw.EntryRow metadata_row;
        private Adw.ComboRow metadata_kind;
        private Adw.SwitchRow upstream_row;
        private Adw.EntryRow evidence_row;
        private Gtk.TextView manual_editor;
        private Gtk.TextView policy_editor;
        private Gtk.TextView assets_editor;
        private Gtk.Button action;
        private Gtk.Label action_label;
        private Adw.Spinner spinner;
        private string update_url;
        private AppHubSubmission? service;
        private Json.Node? reviewed;
        private string? destination;
        private bool busy;
        private string? pending_toast;
        private Cancellable cancel = new Cancellable();
        public signal void matched(AppHubMatch match);

        public AppHubSubmissionPage(InstallationRecord record, AppHubMatch? existing = null) {
            Object(title: _("Submit to AppHub"));
            update_url = record.get_effective_update_link() ?? "";
            var toolbar = new Adw.ToolbarView();
            toolbar.add_top_bar(new Adw.HeaderBar());
            var page = new Adw.PreferencesPage();
            var group = new Adw.PreferencesGroup();
            group.title = _("Application listing");
            group.description = _("AppHub reviews one listing per AppStream ID. Submitting creates a public manifest and pull request in your GitHub account.");
            id_row = entry(_("AppStream ID"), record.flathub_id ?? record.appstream_id ?? "");
            slug_row = entry(_("Listing slug"), make_slug(record.original_name ?? record.name));
            var source_row = new Adw.ActionRow();
            source_row.title = _("Update source");
            source_row.subtitle = Markup.escape_text(update_url);
            group.add(source_row);
            group.add(id_row);
            group.add(slug_row);
            metadata_kind = new Adw.ComboRow();
            metadata_kind.title = _("Metadata source");
            metadata_kind.model = new Gtk.StringList({ _("Flathub"), _("Public MetaInfo XML"), _("Manual metadata") });
            group.add(metadata_kind);
            metadata_row = entry(_("Public HTTPS MetaInfo URL"), "");
            metadata_row.visible = false;
            group.add(metadata_row);
            upstream_row = new Adw.SwitchRow();
            upstream_row.title = _("Published or endorsed by upstream");
            upstream_row.subtitle = _("Otherwise the listing is marked third-party");
            group.add(upstream_row);
            evidence_row = entry(_("Upstream evidence HTTPS URL"), "");
            evidence_row.visible = false;
            group.add(evidence_row);
            page.add(group);

            var manual_group = new Adw.PreferencesGroup();
            manual_group.title = _("Manual AppStream source (JSON)");
            manual_group.description = _("Use only when upstream has no AppStream metadata. Supply metadata, a public icon URL, and at least one screenshot. See the catalog guide for the format.");
            manual_editor = editor("{\n  \"type\": \"manual\",\n  \"metadata\": {\n    \"id\": \"org.example.App\",\n    \"name\": \"Example\",\n    \"summary\": \"A short summary\",\n    \"description\": [{\"type\": \"paragraph\", \"content\": [{\"type\": \"text\", \"value\": \"Describe the application.\"}]}],\n    \"projectLicense\": \"MIT\",\n    \"developer\": {\"name\": \"Example developers\"},\n    \"homepage\": \"https://example.org\",\n    \"categories\": [\"Utility\"]\n  },\n  \"media\": {\n    \"icon\": \"https://example.org/icon.png\",\n    \"screenshots\": [{\"caption\": \"Main window\", \"source\": \"https://example.org/screenshot.png\"}]\n  }\n}");
            manual_group.add(scroll_editor(manual_editor));
            manual_group.visible = false;
            page.add(manual_group);

            var policy_group = new Adw.PreferencesGroup();
            policy_group.title = _("Required sandbox access (AppHub v1 JSON)");
            policy_group.description = _("Prefilled from this app's AppManager sandbox permissions. AppHub enforces these for every installation, so review them before submitting.");
            string[] policy_notes;
            var policy_json = AppHubSubmission.sandbox_policy_json(record, out policy_notes);
            policy_editor = editor(policy_json);
            policy_group.add(scroll_editor(policy_editor));
            if (policy_notes.length > 0) {
                var notes_row = new Adw.ActionRow();
                notes_row.title = _("Review before submitting");
                notes_row.subtitle = string.joinv("\n", policy_notes);
                policy_group.add(notes_row);
            }
            page.add(policy_group);
            var assets_group = new Adw.PreferencesGroup();
            assets_group.title = _("Architecture filename patterns (optional JSON)");
            assets_group.description = _("Leave {} for automatic detection. For ambiguous filenames, use architecture keys and filename patterns ending in .AppImage.");
            assets_editor = editor("{}");
            assets_group.add(scroll_editor(assets_editor, 80));
            page.add(assets_group);

            var guide_group = new Adw.PreferencesGroup();
            var guide = new Adw.ButtonRow();
            guide.title = _("AppHub catalog and sandbox guide");
            guide.end_icon_name = "external-link-symbolic";
            guide.activated.connect(() => {
                UiUtils.open_url("https://github.com/xlc-dev/apphub/blob/main/docs/catalog.md");
            });
            guide_group.add(guide);
            page.add(guide_group);

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            box.margin_top = 12;
            box.margin_bottom = 18;
            box.margin_start = 18;
            box.margin_end = 18;
            action = new Gtk.Button();
            var button_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            button_box.valign = Gtk.Align.CENTER;
            button_box.halign = Gtk.Align.CENTER;
            spinner = new Adw.Spinner();
            spinner.visible = false;
            spinner.valign = Gtk.Align.CENTER;
            button_box.append(spinner);
            action_label = new Gtk.Label(_("Check submission"));
            action_label.valign = Gtk.Align.CENTER;
            button_box.append(action_label);
            action.child = button_box;
            action.add_css_class("pill");
            action.add_css_class("suggested-action");
            action.halign = Gtk.Align.CENTER;
            action.clicked.connect(() => {
                if (destination != null) { UiUtils.open_url(destination); return; }
                run.begin(reviewed != null);
            });
            action.tooltip_text = _("Review the listing information, then check for existing listings and submissions.");
            box.append(action);
            var footer = new Adw.PreferencesGroup();
            footer.add(box);
            page.add(footer);
            toolbar.content = page;
            child = toolbar;

            id_row.notify["text"].connect(reset_review);
            slug_row.notify["text"].connect(reset_review);
            metadata_row.notify["text"].connect(reset_review);
            evidence_row.notify["text"].connect(reset_review);
            policy_editor.buffer.changed.connect(reset_review);
            assets_editor.buffer.changed.connect(reset_review);
            manual_editor.buffer.changed.connect(reset_review);
            metadata_kind.notify["selected"].connect(() => {
                metadata_row.visible = metadata_kind.selected == 1;
                manual_group.visible = metadata_kind.selected == 2;
                reset_review();
            });
            upstream_row.notify["active"].connect(() => {
                evidence_row.visible = upstream_row.active;
                reset_review();
            });
            GitHubAuth.get_apphub().changed.connect(check_access);
            hiding.connect(() => cancel.cancel());
            if (existing != null) {
                destination = existing.url;
                action_label.label = _("View on GitHub");
                pending_toast = existing.message;
            }
            map.connect(() => {
                if (pending_toast != null) {
                    show_toast(pending_toast);
                    pending_toast = null;
                }
            });
            check_access();
        }

        public override void unroot() {
            cancel.cancel();
            base.unroot();
        }

        private void check_access() {
            bool allowed = TokenStore.apphub_enabled() && GitHubAuth.get_apphub().ready;
            action.sensitive = allowed && !busy;
            if (!allowed) cancel.cancel();
            update_action_tooltip();
        }

        private void update_action_tooltip() {
            if (!TokenStore.apphub_enabled() || !GitHubAuth.get_apphub().ready) {
                action.tooltip_text = _("AppHub submissions are disabled. Verify the dedicated token in Preferences → AppHub submissions.");
            } else if (destination != null) {
                action.tooltip_text = _("Open the existing AppHub listing or submission in your browser.");
            } else if (reviewed != null) {
                action.tooltip_text = _("Submit this manifest for AppHub maintainer review.");
            } else {
                action.tooltip_text = _("Review the listing information, then check for existing listings and submissions.");
            }
        }

        /** Routes a message to the main window's toast overlay this page lives in. */
        private void show_toast(string message) {
            if (message == null || message == "") return;
            var window = get_root() as MainWindow;
            if (window != null) window.add_toast(message);
        }

        private static Adw.EntryRow entry(string title, string text) {
            var row = new Adw.EntryRow();
            row.title = title;
            row.text = text;
            return row;
        }

        private static Gtk.TextView editor(string text) {
            var view = new Gtk.TextView();
            view.monospace = true;
            view.wrap_mode = Gtk.WrapMode.WORD_CHAR;
            view.top_margin = view.bottom_margin = view.left_margin = view.right_margin = 10;
            view.buffer.text = text;
            return view;
        }

        private static Gtk.Widget scroll_editor(Gtk.TextView view, int height = 210) {
            var scroll = new Gtk.ScrolledWindow();
            scroll.min_content_height = height;
            scroll.child = view;
            scroll.add_css_class("card");
            return scroll;
        }

        private static string make_slug(string name) {
            try {
                var slug = new Regex("[^a-z0-9]+").replace(name.down(), -1, 0, "-");
                return new Regex("^-|-$").replace(slug, -1, 0, "");
            }
            catch (Error e) { return ""; }
        }

        private void reset_review() {
            reviewed = null;
            destination = null;
            if (!busy) {
                action_label.label = _("Check submission");
                update_action_tooltip();
            }
        }

        private Json.Node prepare() throws Error {
            var source = AppHubSource.parse(update_url);
            if (!Regex.match_simple("^[a-z0-9]+(-[a-z0-9]+)*$", slug_row.text) || slug_row.text.length > 100)
                throw new IOError.INVALID_ARGUMENT(_("Use a lowercase listing slug with hyphens."));
            var manifest = AppHubSubmission.build_manifest(id_row.text.strip(), metadata_kind.selected == 1 ? metadata_row.text.strip() : "", source, policy_editor.buffer.text);
            AppHubSubmission.complete_manifest(manifest, metadata_kind.selected == 2 ? manual_editor.buffer.text : null,
                upstream_row.active ? evidence_row.text.strip() : null, assets_editor.buffer.text);
            return manifest;
        }

        private async void run(bool submit) {
            if (busy || cancel.is_cancelled()) return;
            Json.Node manifest;
            try { manifest = submit ? reviewed.copy() : prepare(); }
            catch (Error e) { show_toast(e.message); return; }
            var token = TokenStore.get_apphub_request_token();
            if (token == null || !TokenStore.apphub_enabled() || !GitHubAuth.get_apphub().ready) { check_access(); return; }
            var slug = slug_row.text;
            busy = true;
            action.sensitive = false;
            // Freeze input, while retaining scrolling and back navigation.
            foreach (var row in new Gtk.Widget[] { id_row, slug_row, metadata_row, metadata_kind, upstream_row, evidence_row, policy_editor, assets_editor, manual_editor }) row.sensitive = false;
            spinner.visible = true;
            AppHubMatch? found = null;
            string? failure = null;
            bool authentication_failed = false;
            SourceFunc callback = run.callback;
            if (service == null) service = new AppHubSubmission(new GitHubClient(token, null, "apphub-token-enabled"));
            new Thread<void>("apphub-submit", () => {
                try {
                    GitHubClient.authenticate(new GitHubClient(token, null, "apphub-token-enabled").request("GET", "/user", null, cancel), true);
                    if (submit) found = service.submit(slug, manifest, cancel);
                    else {
                        var source = AppHubSource.parse(update_url);
                        found = service.check(AppHubSubmission.manifest_id(manifest.get_object()), source, cancel);
                        if (found == null) service.validate_sources(manifest, cancel);
                    }
                } catch (IOError.PERMISSION_DENIED e) { failure = e.message; authentication_failed = true; }
                catch (Error e) { failure = e.message; }
                Idle.add((owned) callback);
            });
            yield;
            busy = false;
            spinner.visible = false;
            foreach (var row in new Gtk.Widget[] { id_row, slug_row, metadata_row, metadata_kind, upstream_row, evidence_row, policy_editor, assets_editor, manual_editor }) row.sensitive = true;
            if (cancel.is_cancelled()) { check_access(); return; }
            action.sensitive = true;
            if (failure != null) {
                if (authentication_failed) GitHubAuth.get_apphub().invalidate();
                reviewed = null;
                action_label.label = _("Check submission");
                update_action_tooltip();
                show_toast(failure);
            } else if (found != null) {
                destination = found.url;
                action_label.label = _("View on GitHub");
                update_action_tooltip();
                matched(found);
                show_toast(found.message);
            } else {
                reviewed = manifest;
                action_label.label = _("Submit to AppHub");
                update_action_tooltip();
                show_toast(service.source_warning ?? _("No existing listing or open submission found."));
            }
        }
    }
}
