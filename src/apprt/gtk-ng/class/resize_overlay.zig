const std = @import("std");
const assert = std.debug.assert;
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_resize_overlay);

/// The overlay that shows the current size while a surface is resizing.
/// This can be used generically to show pretty much anything with a
/// disappearing overlay, but we have no other use at this point so it
/// is named specifically for what it does.
///
/// General usage:
///
///   1. Add it to an overlay
///   2. Set the label with `setLabel`
///   3. Schedule to show it with `schedule`
///
/// Set any properties to change the behavior.
pub const ResizeOverlay = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyResizeOverlay",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const duration = struct {
            pub const name = "duration";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                c_uint,
                .{
                    .nick = "Duration",
                    .blurb = "The duration this overlay appears in milliseconds.",
                    .default = 750,
                    .minimum = 250,
                    .maximum = std.math.maxInt(c_uint),
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "duration",
                    ),
                },
            );
        };

        pub const @"first-delay" = struct {
            pub const name = "first-delay";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                c_uint,
                .{
                    .nick = "First Delay",
                    .blurb = "The delay in milliseconds before any overlay is shown for the first time.",
                    .default = 250,
                    .minimum = 250,
                    .maximum = std.math.maxInt(c_uint),
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "first_delay",
                    ),
                },
            );
        };

        pub const @"overlay-halign" = struct {
            pub const name = "overlay-halign";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.Align,
                .{
                    .nick = "halign",
                    .blurb = "The alignment of the label.",
                    .default = .center,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "halign",
                    ),
                },
            );
        };

        pub const @"overlay-valign" = struct {
            pub const name = "overlay-valign";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.Align,
                .{
                    .nick = "valign",
                    .blurb = "The alignment of the label.",
                    .default = .center,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "valign",
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// The label with the text
        label: *gtk.Label,

        /// The time that the overlay appears.
        duration: c_uint,

        /// The first delay before any overlay is shown. Must be specified
        /// during construction otherwise it has no effect.
        first_delay: c_uint,

        /// The idle source that we use to update the label.
        idler: ?c_uint = null,

        /// The timer for dismissing the overlay.
        timer: ?c_uint = null,

        /// The first delay timer.
        delay_timer: ?c_uint = null,

        /// The alignment of the label
        halign: gtk.Align,
        valign: gtk.Align,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.C) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        const priv = self.private();
        if (priv.first_delay > 0) {
            priv.delay_timer = glib.timeoutAdd(
                priv.first_delay,
                onDelayTimer,
                self,
            );
        }
    }

    /// Set the label for the overlay. This will not show the
    /// overlay if it is currently hidden; you must call schedule.
    pub fn setLabel(self: *Self, label: [:0]const u8) void {
        const priv = self.private();
        priv.label.setText(label.ptr);
    }

    /// Schedule the overlay to be shown. To avoid flickering during
    /// resizes we schedule the overlay to be shown on the next idle tick.
    pub fn schedule(self: *Self) void {
        const priv = self.private();

        // If we have a delay timer then we're not showing anything
        // yet so do nothing.
        if (priv.delay_timer != null) return;

        // When updating a widget, wait until GTK is "idle", i.e. not in the middle
        // of doing any other updates. Since we are called in the middle of resizing
        // GTK is doing a lot of work rearranging all of the widgets. Not doing this
        // results in a lot of warnings from GTK and _horrible_ flickering of the
        // resize overlay.
        if (priv.idler != null) return;
        priv.idler = glib.idleAdd(onIdle, self);
    }

    fn onIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();

        // No matter what our idler is complete with this callback
        priv.idler = null;

        // Show ourselves
        self.as(gtk.Widget).setVisible(1);

        if (priv.timer) |timer| {
            if (glib.Source.remove(timer) == 0) {
                log.warn("unable to remove size overlay timer", .{});
            }
        }

        priv.timer = glib.timeoutAdd(
            priv.duration,
            onTimer,
            self,
        );

        return 0;
    }

    fn onTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.timer = null;
        self.as(gtk.Widget).setVisible(0);
        return 0;
    }

    fn onDelayTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.delay_timer = null;
        return 0;
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.C) void {
        const priv = self.private();
        if (priv.idler) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove resize overlay idler", .{});
            }
            priv.idler = null;
        }
        if (priv.timer) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove resize overlay timer", .{});
            }
            priv.timer = null;
        }
        if (priv.delay_timer) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove resize overlay delay timer", .{});
            }
            priv.delay_timer = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.C) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 2,
                    .name = "resize-overlay",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("label", .{});

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.duration.impl,
                properties.@"first-delay".impl,
                properties.@"overlay-halign".impl,
                properties.@"overlay-valign".impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
