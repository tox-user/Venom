/*
 *    ApplicationWindow.vala
 *
 *    Copyright (C) 2013-2018  Venom authors and contributors
 *
 *    This file is part of Venom.
 *
 *    Venom is free software: you can redistribute it and/or modify
 *    it under the terms of the GNU General Public License as published by
 *    the Free Software Foundation, either version 3 of the License, or
 *    (at your option) any later version.
 *
 *    Venom is distributed in the hope that it will be useful,
 *    but WITHOUT ANY WARRANTY; without even the implied warranty of
 *    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *    GNU General Public License for more details.
 *
 *    You should have received a copy of the GNU General Public License
 *    along with Venom.  If not, see <http://www.gnu.org/licenses/>.
 */

namespace Venom {
  [GtkTemplate(ui = "/chat/tox/venom/ui/application_window.ui")]
  public class ApplicationWindow : Gtk.ApplicationWindow, ContactListWidgetCallback {

    private const GLib.ActionEntry win_entries[] =
    {
      { "add_contact",  on_add_contact },
      { "copy_id",      on_copy_id },
      { "filetransfer", on_filetransfer },
      { "groupchats",   on_create_groupchat },
      { "show_user",    on_show_user },
      { "change_userstatus", on_change_userstatus, "s", "'online'" },
      { "show-contact-details", on_show_contact_details, "s", null, null },
      { "invite-to-conference", on_invite_to_conference, "s", null, null }
    };

    [GtkChild] private Gtk.Box contact_list_box;
    [GtkChild] private Gtk.Bin content_bin;
    [GtkChild] private Gtk.StatusIcon status_icon;
    [GtkChild] private Gtk.Paned content_paned;
    [GtkChild] public Gtk.Box user_info_box;
    [GtkChild] public Gtk.HeaderBar header_bar;
    [GtkChild] public Gtk.Box header_start;
    [GtkChild] public Gtk.Box header_end;

    private unowned Factory.IWidgetFactory widget_factory;
    private ILogger logger;
    private ISettingsDatabase settings_database;
    private IContactDatabase contact_database;
    private IDhtNodeDatabase node_database;
    private ToxSession session;
    private ToxAdapterFriendListenerImpl friend_listener;
    private ToxAdapterConferenceListenerImpl conference_listener;
    private ToxAdapterFiletransferListenerImpl filetransfer_listener;
    private ToxAdapterSelfListenerImpl session_listener;
    private NotificationListener notification_listener;
    private WindowState window_state;
    private unowned ContactListViewModel contact_list_view_model;

    private ObservableList contacts;
    private ObservableList transfers;
    private ObservableList friend_requests;
    private ObservableList conference_invites;

    private GLib.HashTable<IContact, ObservableList> conversations;
    private UserInfo user_info;

    public ApplicationWindow(Gtk.Application application, Factory.IWidgetFactory widget_factory, ToxSession session,
                             IDhtNodeDatabase node_database, ISettingsDatabase settings_database, IContactDatabase contact_database) {
      Object(application: application);

      conversations = new GLib.HashTable<IContact, ObservableList>(null, null);
      user_info = new UserInfoImpl();

      this.widget_factory = widget_factory;
      this.logger = widget_factory.createLogger();
      logger.attach_to_glib();

      this.node_database = node_database;
      this.settings_database = settings_database;
      this.contact_database = contact_database;

      contacts = new ObservableList();
      contacts.set_list(new GLib.List<IContact>());
      transfers = new ObservableList();
      transfers.set_list(new GLib.List<FileTransfer>());
      friend_requests = new ObservableList();
      friend_requests.set_list(new GLib.List<FriendRequest>());
      conference_invites = new ObservableList();
      conference_invites.set_list(new GLib.List<ConferenceInvite>());

      notification_listener = new NotificationListenerImpl(logger);
      notification_listener.clear_notifications();

      session_listener = new ToxAdapterSelfListenerImpl(logger, user_info);
      friend_listener = new ToxAdapterFriendListenerImpl(logger, user_info, contacts, friend_requests, conversations, notification_listener);
      conference_listener = new ToxAdapterConferenceListenerImpl(logger, contacts, conference_invites, conversations, notification_listener);
      filetransfer_listener = new ToxAdapterFiletransferListenerImpl(logger, transfers, conversations, notification_listener);

      settings_database.bind_property("enable-send-typing", friend_listener, "show-typing", BindingFlags.SYNC_CREATE);
      settings_database.bind_property("enable-notification-sounds", notification_listener, "play-sound-notifications", BindingFlags.SYNC_CREATE);
      settings_database.bind_property("enable-tray", status_icon, "visible", BindingFlags.SYNC_CREATE);

      update_notifications();
      user_info.notify["user-status"].connect(update_notifications);
      settings_database.notify["enable-urgency-notification"].connect(update_notifications);
      settings_database.notify["enable-notification-busy"].connect(update_notifications);

      user_info.notify["user-status"].connect(on_user_status_changed);

      init_callbacks();
      init_window_state();
      init_widgets();

      session_listener.attach_to_session(session);
      friend_listener.attach_to_session(session);
      conference_listener.attach_to_session(session);
      filetransfer_listener.attach_to_session(session);

      status_icon.activate.connect(on_status_icon_activate);
      delete_event.connect(on_delete_event);
      focus_in_event.connect(on_focus_in_event);
      window_state_event.connect(on_window_state_event);
      size_allocate.connect(on_window_size_allocate);
      content_paned.bind_property("position", window_state, "paned_position", BindingFlags.SYNC_CREATE);

      show_welcome();

      logger.d("ApplicationWindow created.");
    }

    ~ApplicationWindow() {
      logger.d("ApplicationWindow destroyed.");
      save_window_state();
    }

    private void on_status_icon_activate() {
      if (is_active) {
        hide();
      } else {
        present();
      }
    }

    private bool on_focus_in_event() {
      notification_listener.clear_notifications();
      return false;
    }

    private bool on_delete_event() {
      if (settings_database.enable_tray && settings_database.enable_tray_minimize) {
        return hide_on_delete();
      }
      return false;
    }

    private bool on_window_state_event(Gdk.EventWindowState event) {
      window_state.is_maximized = Gdk.WindowState.MAXIMIZED in event.new_window_state;
      window_state.is_fullscreen = Gdk.WindowState.FULLSCREEN in event.new_window_state;
      return Gdk.EVENT_PROPAGATE;
    }

    private void on_window_size_allocate(Gtk.Allocation allocation) {
      if (!window_state.is_maximized && !window_state.is_fullscreen) {
        int width, height;
        get_size(out width, out height);
        window_state.width = width;
        window_state.height = height;
      }
    }

    private void init_window_state() {
      try {
        var window_state_string = FileIO.load_contents_text(R.constants.window_state_filename());
        window_state = WindowState.deserialize(window_state_string);
      } catch (Error e) {
        logger.i("Loading window state failed: " + e.message);
        window_state = new WindowState();
      }
      set_window_state();
    }

    private void set_window_state() {
      set_default_size(window_state.width, window_state.height);
      if (window_state.is_maximized) {
        maximize();
      }
      if (window_state.is_fullscreen) {
        fullscreen();
      }
      content_paned.position = window_state.paned_position;
    }

    private void save_window_state() {
      try {
        var data = WindowState.serialize(window_state);
        FileIO.save_contents_text(R.constants.window_state_filename(), data);
      } catch (Error e) {
        logger.e("Saving window state failed: " + e.message);
      }
    }

    private void init_widgets() {
      var screen = Gdk.Screen.get_default();
      var css_provider = new Gtk.CssProvider();
      css_provider.load_from_resource("/chat/tox/venom/css/custom.css");
      Gtk.StyleContext.add_provider_for_screen(screen, css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

      var gtk_settings = Gtk.Settings.get_default();
      settings_database.bind_property("enable-dark-theme", gtk_settings, "gtk-application-prefer-dark-theme", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
      settings_database.bind_property("enable-animations", gtk_settings, "gtk-enable-animations", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);

      set_default_icon_name(R.icons.app);
      var icon_theme = Gtk.IconTheme.get_default();
      try {
        set_default_icon(icon_theme.load_icon(R.icons.app, 48, 0));
      } catch (Error e) {
        logger.f("Could not set icon from theme: " + e.message);
      }

      var contact_list = new ContactListWidget(logger, this, contacts, friend_requests, conference_invites, this, user_info, settings_database);
      contact_list_box.pack_start(contact_list, true, true);
      contact_list_view_model = contact_list.get_model();
      content_paned.bind_property("position", user_info_box, "width-request", BindingFlags.SYNC_CREATE,
                                  (binding, source, ref target) => { target = source.get_int() - 12; return true; });

      var app = GLib.Application.get_default() as Gtk.Application;
      app.set_accels_for_action("win.undo", { "<Control>Z" });
      app.set_accels_for_action("win.redo", { "<Control>Y" });
    }

    public void reset_header_bar() {
      header_start.@foreach((w) => { w.destroy(); });
      header_end.@foreach((w) => { w.destroy(); });
      header_bar.custom_title = null;
      header_bar.title = "";
      header_bar.subtitle = "";
    }

    public virtual void on_contact_selected(IContact contact) {
      logger.d("ApplicationWindow on_contact_selected");
      if (contact is Contact) {
        var conv = conversations.@get(contact);
        switch_content_with(() => { return new ConversationWindow(this, logger, conv, contact, settings_database, friend_listener, filetransfer_listener, filetransfer_listener); });
      } else if (contact is Conference) {
        var conv = conversations.@get(contact);
        switch_content_with(() => { return new ConferenceWindow(this, logger, conv, contact, settings_database, conference_listener); });
      }
    }

    private void init_callbacks() {
      add_action_entries(win_entries, this);
    }

    public void show_settings() {
      switch_content_with(() => { return widget_factory.createSettingsWidget(this, settings_database, node_database); });
    }

    public void show_welcome() {
      switch_content_with(() => { return new WelcomeWidget(logger, this); });
    }

    private void on_show_user() {
      switch_content_with(() => { return new UserInfoWidget(logger, this, user_info, session_listener); });
    }

    public void on_create_groupchat() {
      switch_content_with(() => { return new CreateGroupchatWidget(logger, this, conference_invites, conference_listener, conference_listener); });
    }

    public void on_filetransfer() {
      switch_content_with(() => { return new FileTransferWidget(logger, this, transfers, filetransfer_listener); });
    }

    public void on_show_friend(IContact contact) {
      switch_content_with(() => { return new FriendInfoWidget(logger, this, friend_listener, contact, settings_database); });
    }

    public void on_show_conference(IContact contact) {
      switch_content_with(() => { return new ConferenceInfoWidget(logger, this, conference_listener, contact, settings_database); });
    }

    private IContact ? find_contact(string contact_id) {
      for (var i = 0; i < contacts.length(); i++) {
        var c = contacts.nth_data(i) as IContact;
        if (c.get_id() == contact_id) {
          return c;
        }
      }
      return null;
    }

    public void on_show_contact(string contact_id) {
      logger.d(@"on_show_contact($contact_id)");
      var c = find_contact(contact_id);
      if (c != null) {
        on_contact_selected(c);
      } else {
        logger.i(@"Friend with id $contact_id not found.");
      }
    }

    public void on_show_contact_details(GLib.SimpleAction action, GLib.Variant? parameter) {
      if (parameter == null) {
        return;
      }

      var contact_id = parameter.get_string();
      logger.d(@"on_show_contact_details($contact_id)");
      var c = find_contact(contact_id);
      if (c == null) {
        logger.i(@"Friend with id $contact_id not found.");
        return;
      }
      if (c is Contact) {
        on_show_friend(c);
      } else if (c is Conference) {
        on_show_conference(c);
      }
    }

    public void on_invite_to_conference(GLib.SimpleAction action, GLib.Variant? parameter) {
      if (parameter == null) {
        return;
      }

      var contact_id = parameter.get_string();
      logger.d(@"on_invite_to_conference($contact_id)");
      contact_list_view_model.on_invite_to_conference(contact_id);
    }

    public void on_invite_id_to_conference(IContact contact, string id) {
      try {
        conference_listener.on_send_conference_invite(contact, id);
      } catch (Error e) {
        logger.e("Could not send conference invite: " + e.message);
      }
    }

    private void update_notifications() {
      notification_listener.show_notifications = settings_database.enable_urgency_notification &&
        (settings_database.enable_notification_busy || user_info.user_status != UserStatus.BUSY);
    }

    private void on_user_status_changed() {
      var action = lookup_action("change_userstatus") as SimpleAction;
      switch (user_info.user_status) {
        case UserStatus.NONE:
          action.set_state("online");
          break;
        case UserStatus.AWAY:
          action.set_state("away");
          break;
        case UserStatus.BUSY:
          action.set_state("busy");
          break;
      }
    }

    private void on_change_userstatus(GLib.SimpleAction action, GLib.Variant? parameter) {
      logger.d("on_change_userstatus()");
      var status = parameter.get_string();
      switch (status) {
        case "online":
          session_listener.self_set_user_status(UserStatus.NONE);
          break;
        case "away":
          session_listener.self_set_user_status(UserStatus.AWAY);
          break;
        case "busy":
          session_listener.self_set_user_status(UserStatus.BUSY);
          break;
      }
    }

    public void on_add_contact() {
      logger.d("on_add_contact()");
      switch_content_with(() => {
        var widget = new AddContactWidget(logger, this, friend_requests, friend_listener, friend_listener);
        return widget;
      });
    }

    private void on_copy_id() {
      logger.d("on_copy_id()");
      var clipboard = Gtk.Clipboard.@get(Gdk.SELECTION_CLIPBOARD);
      var id = user_info.tox_id;
      clipboard.set_text(id, id.length);
    }

    private void switch_content_with(owned WidgetProvider widget_provider) {
      {
        var previous = content_bin.get_child();
        if (previous != null) {
          previous.destroy();
        }
      }

      var current = widget_provider();
      current.show_all();
      content_bin.add(current);
    }

    public delegate Gtk.Widget WidgetProvider();
  }
}
