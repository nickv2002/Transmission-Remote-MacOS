%define  debug_package %{nil}

#  FPC source bundle: https://gitlab.com/freepascal.org/fpc/source/-/archive/56baf314b5ebf4e5a44fe3e214914fa2e1b34adb/source-56baf314b5ebf4e5a44fe3e214914fa2e1b34adb.tar.bz2

Name:		fpc
Version:	3.2.4
Release:	5%{?dist}
Summary:	Free Pascal Compiler
License:	GPLv2+ and LGPLv2+ with exceptions # https://wiki.lazarus.freepascal.org/FPC_modified_LGPL
URL:		https://www.freepascal.org
Source0:	%{name}-%{version}.tar.gz
BuildArch:	x86_64

#  Set a macro to the name of the main executable, based on the system
#  architecture we're building for.
%ifarch %{arm}
  %global ppcname ppcarm
%else
  %ifarch aarch64
    %global ppcname ppca64
  %else
    %ifarch ppc64 ppc64le
      %global ppcname ppcppc64
    %else
      %ifarch x86_64
        %global ppcname ppcx64
      %else
        %glqobal ppcname ppc386
      %endif
    %endif
  %endif
%endif

Requires:		binutils
%if 0%{?fedora} > 43
BuildRequires:	fpc
%else
BuildRequires:	fpc == 3.2.2
%endif
BuildRequires: 	glibc-devel
BuildRequires:	qt5pas-devel
BuildRequires:  libX11-devel

%description
An updated, development version of the Free Pascal Compiler, intended only to
be used in the COPR build environment for building lighterowl's transgui 
package.  Do not install this on your workstation, it will break stuff.

%prep
%setup -q

%build
make all

%install
make install INSTALL_PREFIX=%{buildroot}/usr
mv %{buildroot}/usr/lib %{buildroot}%{_libdir}
ln -sf %{_libdir}/%{name}/%{version}/%{ppcname} %{buildroot}%{_bindir}/%{ppcname}

%files
%{_bindir}/*
%{_libdir}/%{name}
%{_libdir}/libpas2jslib.so*
%dir %{_defaultdocdir}/%{name}-%{version}/
%doc %{_defaultdocdir}/%{name}-%{version}/*

%post
%{_libdir}/%{name}/%{version}/samplecfg %{_libdir}/%{name}/%version} %{_sysconfdir}

%changelog
* Thu Oct 02 2025 dlk3 <dave@daveking.com> 3.2.4-5
- Rebuilding package on COPR (without tito) 

* Fri Jun 06 2025 dlk3 <dave@daveking.com> 3.2.4-4
- Rebuilding package with tito

* Thu Jun 05 2025 dlk3 <dave@daveking.com> 3.2.4-3
- Test removing --nowait option from COPR build process (dave@daveking.com)

* Thu Jun 05 2025 dlk3 <dave@daveking.com> 3.2.4-2
- Developing spec file to work with tito build (dave@daveking.com)

* Sun Jun 08 2025 dlk3 <dave@daveking.com> 3.2.4-0
- Initial version of package
