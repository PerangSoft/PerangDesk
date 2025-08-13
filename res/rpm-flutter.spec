Name:       perangdesk
Version:    1.4.1
Release:    0
Summary:    RPM package
License:    GPL-3.0
URL:        https://rustdesk.com
Vendor:     perangdesk <info@perangdesk.com>
Requires:   gtk3 libxcb libxdo libXfixes alsa-lib libva pam gstreamer1-plugins-base
Recommends: libayatana-appindicator-gtk3
Provides:   libdesktop_drop_plugin.so()(64bit), libdesktop_multi_window_plugin.so()(64bit), libfile_selector_linux_plugin.so()(64bit), libflutter_custom_cursor_plugin.so()(64bit), libflutter_linux_gtk.so()(64bit), libscreen_retriever_plugin.so()(64bit), libtray_manager_plugin.so()(64bit), liburl_launcher_linux_plugin.so()(64bit), libwindow_manager_plugin.so()(64bit), libwindow_size_plugin.so()(64bit), libtexture_rgba_renderer_plugin.so()(64bit)

# https://docs.fedoraproject.org/en-US/packaging-guidelines/Scriptlets/

%description
The best open-source remote desktop client software, written in Rust.

%prep
# we have no source, so nothing here

%build
# we have no source, so nothing here

# %global __python %{__python3}

%install

mkdir -p "%{buildroot}/usr/share/perangdesk" && cp -r ${HBB}/flutter/build/linux/x64/release/bundle/* -t "%{buildroot}/usr/share/perangdesk"
mkdir -p "%{buildroot}/usr/bin"
install -Dm 644 $HBB/res/perangdesk.service -t "%{buildroot}/usr/share/rustdesk/files"
install -Dm 644 $HBB/res/perangdesk.desktop -t "%{buildroot}/usr/share/rustdesk/files"
install -Dm 644 $HBB/res/perangdesk-link.desktop -t "%{buildroot}/usr/share/rustdesk/files"
install -Dm 644 $HBB/res/128x128@2x.png "%{buildroot}/usr/share/icons/hicolor/256x256/apps/perangdesk.png"
install -Dm 644 $HBB/res/scalable.svg "%{buildroot}/usr/share/icons/hicolor/scalable/apps/perangdesk.svg"

%files
/usr/share/rustdesk/*
/usr/share/rustdesk/files/perangdesk.service
/usr/share/icons/hicolor/256x256/apps/perangdesk.png
/usr/share/icons/hicolor/scalable/apps/perangdesk.svg
/usr/share/rustdesk/files/perangdesk.desktop
/usr/share/rustdesk/files/perangdesk-link.desktop

%changelog
# let's skip this for now

%pre
# can do something for centos7
case "$1" in
  1)
    # for install
  ;;
  2)
    # for upgrade
    systemctl stop perangdesk || true
  ;;
esac

%post
cp /usr/share/rustdesk/files/perangdesk.service /etc/systemd/system/perangdesk.service
cp /usr/share/rustdesk/files/perangdesk.desktop /usr/share/applications/
cp /usr/share/rustdesk/files/perangdesk-link.desktop /usr/share/applications/
ln -sf /usr/share/rustdesk/perangdesk /usr/bin/perangdesk
systemctl daemon-reload
systemctl enable perangdesk
systemctl start perangdesk
update-desktop-database

%preun
case "$1" in
  0)
    # for uninstall
    systemctl stop perangdesk || true
    systemctl disable perangdesk || true
    rm /etc/systemd/system/perangdesk.service || true
  ;;
  1)
    # for upgrade
  ;;
esac

%postun
case "$1" in
  0)
    # for uninstall
    rm /usr/bin/perangdesk || true
    rmdir /usr/lib/perangdesk || true
    rmdir /usr/local/perangdesk || true
    rmdir /usr/share/perangdesk || true
    rm /usr/share/applications/perangdesk.desktop || true
    rm /usr/share/applications/perangdesk-link.desktop || true
    update-desktop-database
  ;;
  1)
    # for upgrade
    rmdir /usr/lib/perangdesk || true
    rmdir /usr/local/perangdesk || true
  ;;
esac
