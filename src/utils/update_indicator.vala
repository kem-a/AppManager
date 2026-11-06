namespace AppManager.Utils {
    public enum UpdatePhase {
        WAITING,
        CHECKING,
        DOWNLOADING,
        INSTALLING,
        FAILED
    }

    /** One update's lifecycle, shared by the library and details presentations. */
    public class UpdateIndicatorState : Object {
        public const uint DISMISS_DURATION = 350;

        public UpdatePhase phase { get; private set; default = UpdatePhase.WAITING; }
        public int64 received { get; private set; default = 0; }
        public int64 total { get; private set; default = 0; }
        public string? message { get; private set; }
        public bool dismissing { get; private set; default = false; }
        public bool finished { get; private set; default = false; }
        public int64 dismiss_started_at { get; private set; default = 0; }
        // Failures remain visible until another check/update replaces them.
        public bool terminal {
            get { return phase == UpdatePhase.FAILED || dismissing; }
        }

        public signal void changed();
        public signal void dismissed();

        // A success needs no badge: the ring collapses while the row leaves
        // the pending group.
        public void dismiss() {
            if (dismissing) {
                return;
            }
            dismissing = true;
            dismiss_started_at = get_monotonic_time();
            changed();
            Timeout.add(DISMISS_DURATION, () => {
                finished = true;
                changed();
                dismissed();
                return Source.REMOVE;
            });
        }

        public void show_phase(UpdatePhase phase, int64 received = 0, int64 total = 0, string? message = null) {
            // Finalization and registry refreshes must not replay the failure badge.
            if (this.phase == phase && terminal) {
                if (message != null && message != this.message) {
                    this.message = message;
                    changed();
                }
                return;
            }
            this.phase = phase;
            this.received = received;
            this.total = total;
            this.message = message;
            changed();
        }
    }

    /**
     * Per-app update progress, drawn by an animated Gtk.Svg (GTK 4.22).
     * States in update-progress.svg: waiting, checking, downloading,
     * p1..p20 (rim filled in 5% steps), installing, failed.
     */
    public class UpdateIndicator : Adw.Bin {
        private const string RESOURCE = "/com/github/AppManager/update-progress.svg";
        private const uint STATE_DOWNLOADING = 2;
        private const uint PROGRESS_STEPS = 20;
        private const uint STATE_INSTALLING = 23;
        private const uint STATE_FAILED = 24;

        private Gtk.Image image;
        private Gtk.Svg? svg = null;
        private uint state = 0;
        private Adw.TimedAnimation dismiss_animation;
        private double display_scale = 1;
        private bool dismissal_started = false;

        public UpdateIndicatorState status { get; private set; }
        public UpdatePhase phase { get { return status.phase; } }

        public int pixel_size {
            get { return image.pixel_size; }
            set { image.pixel_size = value; }
        }

        public UpdateIndicator(UpdateIndicatorState? status = null) {
            this.status = status ?? new UpdateIndicatorState();
            image = new Gtk.Image();
            image.add_css_class("update-indicator");
            child = image;
            can_target = false;
            weak UpdateIndicator indicator = this;
            var target = new Adw.CallbackAnimationTarget((value) => {
                indicator.display_scale = value;
                indicator.queue_draw();
            });
            dismiss_animation = new Adw.TimedAnimation(this, 1, 0, UpdateIndicatorState.DISMISS_DURATION, target);
            dismiss_animation.easing = Adw.Easing.EASE_IN_CUBIC;
            realize.connect(start_playing);
            map.connect(sync_state);
            this.status.changed.connect(sync_state);
            sync_state();
        }

        public void show_phase(UpdatePhase phase, int64 received = 0, int64 total = 0, string? message = null) {
            status.show_phase(phase, received, total, message);
        }

        private void sync_state() {
            switch (phase) {
                case UpdatePhase.CHECKING:
                    state = 1;
                    break;
                case UpdatePhase.DOWNLOADING:
                    state = STATE_DOWNLOADING;
                    if (status.total > 0) {
                        state += (uint) (int64.min(status.received, status.total) * PROGRESS_STEPS / status.total);
                    }
                    break;
                case UpdatePhase.INSTALLING:
                    state = STATE_INSTALLING;
                    break;
                case UpdatePhase.FAILED:
                    state = STATE_FAILED;
                    break;
                default:
                    state = 0;
                    break;
            }
            if (svg != null) {
                svg.state = state;
            }
            tooltip_text = status.message;
            visible = !status.finished;
            if (!status.dismissing) {
                dismiss_animation.reset();
                display_scale = 1;
                dismissal_started = false;
            } else if (!dismissal_started && get_mapped() && !status.finished) {
                dismissal_started = true;
                // A details page opened mid-dismissal joins the same timeline.
                double elapsed = (get_monotonic_time() - status.dismiss_started_at) / 1000.0;
                double t = double.min(1, elapsed / UpdateIndicatorState.DISMISS_DURATION);
                dismiss_animation.value_from = 1 - t * t * t;
                dismiss_animation.duration = (uint) double.max(1, UpdateIndicatorState.DISMISS_DURATION - elapsed);
                dismiss_animation.play();
            }
            queue_draw();
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            if (display_scale <= 0) {
                return;
            }
            snapshot.save();
            float cx = get_width() / 2.0f;
            float cy = get_height() / 2.0f;
            snapshot.translate(Graphene.Point() { x = cx, y = cy });
            snapshot.scale((float) display_scale, (float) display_scale);
            snapshot.translate(Graphene.Point() { x = -cx, y = -cy });
            base.snapshot(snapshot);
            snapshot.restore();
        }

        public override void unmap() {
            base.unmap();
            dismissal_started = false;
        }

        // A state set before playback is lost when the SVG timeline starts,
        // so the paintable is created on first realize in the current state.
        private void start_playing() {
            if (svg == null) {
                try {
                    var bytes = GLib.resources_lookup_data(RESOURCE, GLib.ResourceLookupFlags.NONE);
                    // Resource data is always NUL-terminated.
                    var text = ((string) bytes.get_data()).replace("gpa:state='0'", "gpa:state='%u'".printf(state));
                    svg = new Gtk.Svg.from_bytes(new Bytes(text.data));
                } catch (Error e) {
                    warning("Failed to load update indicator: %s", e.message);
                    return;
                }
                image.paintable = svg;
            }
            svg.set_frame_clock(get_frame_clock());
            svg.play();
        }
    }
}
