%define  debug_package %{nil}

#  Lazarus source bundle: https://gitlab.com/dkk089/lazarus/-/archive/cadda6230398688d6106fe37fb0673a9a2bf0cf3/lazarus-cadda6230398688d6106fe37fb0673a9a2bf0cf3.tar.bz2

Name:		lazarus
Version:	4.0.0
Release:	0%{?dist}
Summary:	Lazarus Component Library and IDE for Free Pascal
License:	GPLv2+ and LGPLv2+ with exceptions # https://sourceforge.net/p/lazarus/laz.git/ci/lazarus_4_0/tree/COPYING.txt
URL:		https://www.lazarus-ide.org/
Source0:	%{name}-%{version}.tar.gz
BuildArch:	x86_64

Requires:	fpc >= 3.2.4
BuildRequires:	fpc >= 3.2.4
BuildRequires:  binutils
BuildRequires:  desktop-file-utils
BuildRequires:  gcc-c++
BuildRequires:  glibc-devel
BuildRequires:  gtk2-devel
BuildRequires:  libappstream-glib
BuildRequires:  make
BuildRequires:  perl-generators
BuildRequires:  qt5-qtbase-devel
BuildRequires:  qt5-qtx11extras-devel
BuildRequires:  qt6-qtbase-devel
BuildRequires:  qt5pas-devel
BuildRequires:  libX11-devel

%description
Lazarus is an IDE to create (graphical and console) applications with
Free Pascal, the (L)GPLed Pascal and Object Pascal compiler that runs on
Windows, Linux, Mac OS X, FreeBSD and more.

Lazarus is the missing part of the puzzle that will allow you to develop
programs for all of the above platforms in a Delphi-like environment.
The IDE is a RAD tool that includes a form designer.

Unlike Java's "write once, run anywhere" motto, Lazarus and Free Pascal
strive for "write once, compile anywhere". Since the exact same compiler
is available on all of the above platforms you don't need to do any recoding
to produce identical products for different platforms.

In short, Lazarus is a free RAD tool for Free Pascal using its
Lazarus Component Library (LCL).

%prep
%setup -q

%build
make bigide LCL_PLATFORM=qt5

%install
make install INSTALL_PREFIX=%{buildroot}/usr
install -d %{buildroot}%{_sysconfdir}/lazarus
sed 's#__LAZARUSDIR__#%{_datadir}/%{name}#;s#__FPCSRCDIR__#%{_libdir}/%{name}/%{version}#' \
        %{buildroot}%{_datadir}/lazarus/tools/install/linux/environmentoptions.xml \
        > %{buildroot}%{_sysconfdir}/lazarus/environmentoptions.xml

%files
%{_bindir}/*
%{_datadir}/*
%{_sysconfdir}/lazarus/*

%changelog
* Thu Jun 05 2025 dlk3 <dave@daveking.com> 4.0.0-0
- Initial version of package
