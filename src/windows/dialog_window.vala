using AppManager.Core;
using AppManager.Utils;

namespace AppManager {
    public class DialogWindow : Adw.Window {
        public signal void option_selected(string response_id);

        private Gtk.Box body_box;
        private Gtk.Box action_box;
        private bool actions_initialized = false;

        public DialogWindow(Application app, Gtk.Window parent, string title, Gtk.Image? icon = null) {
            Object(application: app,
                modal: true,
                resizable: false,
                destroy_with_parent: true,
                width_request: 220,
                default_width: 280);

            if (parent != null) {
                set_transient_for(parent);
            }

            var toolbar_view = new Adw.ToolbarView();
            content = toolbar_view;

            var header = new Adw.HeaderBar();
            header.set_show_end_title_buttons(false);
            header.set_show_start_title_buttons(false);
            header.margin_top = 20;
            var title_label = new Gtk.Label(title);
            title_label.add_css_class("title-4");
            header.set_title_widget(title_label);
            toolbar_view.add_top_bar(header);

            var clamp = new Adw.Clamp();
            clamp.margin_top = 20;
            clamp.margin_bottom = 20;
            clamp.margin_start = 20;
            clamp.margin_end = 20;
            clamp.maximum_size = 280;
            clamp.tightening_threshold = 220;
            toolbar_view.content = clamp;

            body_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 18);
            body_box.halign = Gtk.Align.FILL;
            body_box.hexpand = true;
            clamp.child = body_box;

            if (icon != null) {
                body_box.append(icon);
            }

            action_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            action_box.halign = Gtk.Align.FILL;
            action_box.hexpand = true;
        }

        public void append_body(Gtk.Widget widget) {
            body_box.append(widget);
        }

        public void add_option(string response_id, string label, bool is_default = false) {
            if (!actions_initialized) {
                body_box.append(action_box);
                actions_initialized = true;
            }

            var button = new Gtk.Button.with_label(label);
            button.halign = Gtk.Align.FILL;
            button.hexpand = true;
            button.set_size_request(-1, 40);
            if (is_default) {
                button.add_css_class("suggested-action");
            }
            action_box.append(button);
            button.clicked.connect(() => {
                option_selected(response_id);
                this.close();
            });
        }
    }

    public class UninstallNotification : Object {
        public static DialogWindow present(Application app, Gtk.Window? parent, InstallationRecord record) {
            var dialog = new DialogWindow(app, parent, I18n.tr("App removed"), build_image(record));

            var app_name = record.name ?? record.installed_path;
            if (app_name != null && app_name.strip() != "") {
                var markup = "<b>%s</b>".printf(GLib.Markup.escape_text(app_name, -1));
                dialog.append_body(UiUtils.create_wrapped_label(markup, true));
            }

            dialog.append_body(UiUtils.create_wrapped_label(I18n.tr("The application was uninstalled successfully.")));
            dialog.add_option("close", I18n.tr("Close"), true);
            dialog.present();
            return dialog;
        }

        private static Gtk.Image build_image(InstallationRecord record) {
            var image = new Gtk.Image();
            image.set_pixel_size(64);
            image.halign = Gtk.Align.CENTER;
            var paintable = UiUtils.load_record_icon(record);
            if (paintable != null) {
                image.set_from_paintable(paintable);
            } else {
                image.set_from_icon_name("application-x-executable");
            }
            return image;
        }
    }
}
