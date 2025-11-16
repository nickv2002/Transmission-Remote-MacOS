# Building transgui for Fedora 41+

I have created an installation RPM package for [lighterowl's fork of transgui](https://github.com/lighterowl/transgui) in my [Fedora Copr repository](https://copr.fedorainfracloud.org/coprs/dlk/transgui/).  If all you want to do is to install transgui on Fedora 41, 42, or rawhide, you can do that using these commands:

    sudo dnf copr enable dlk/transgui
    sudo dnf install transgui

## How I built transgui in Copr

Building this version of transgui requires development versions of the Free Pascal Compiler and its IDE tool Lazarus.  As far as I can tell, RPMs for the development versions of these applications are not available anywhere else.  RPMs for them must be built first, and then be made available as dependencies during the transgui Copr build.  

The following sections describe how I built the transgui RPM package on Copr.

### Create two Copr projects, transgui and transgui-sdk

If you do not already have [copr-cli set up on your workstation](https://developer.fedoraproject.org/deployment/copr/copr-cli.html) you'll have to do that first.   When that is set up, then you can create the two new projects in Copr.  That can be done via the Copr web interface or by entering these commands. (Substitute your Copr userid for "${USERID}" in the commands.)

    copr-cli create --chroot fedora-41-x86_64 --chroot fedora-42-x86_64 --chroot fedora-rawhide-x86_64 transgui-sdk
    copr-cli modify --repo "copr://${USERID}/transgui-sdk" transgui-sdk
    copr-cli create --repo "copr://${USERID}/transgui-sdk" --chroot fedora-41-x86_64 --chroot fedora-42-x86_64 --chroot fedora-rawhide-x86_64 transgui
    
### Build fpc and lazarus in the transgui-sdk project repository

I have provided two scripts that demonstrate how to do this, **copr-build-fpc** and **copr-build-lazarus**

The **copr-build-fpc** script must be run first and complete successfully before the **copr-build-lazarus** script can be run.  Lazarus needs to be compiled using the version of fpc that is built in the **fpc** package. 

### Build transgui in the transgui project repository

After the **fpc** and **lazarus** packages are ready in the transgui-sdk repository, then the **copr-build-transgui** script can be run to create the **transgui** package in the transgui project repository.

## How to build your own Fedora package by hand

I have provided a script called **build-transgui** that will perform the steps necessary to build an RPM for transgui in a podman (Docker) container on a Fedora system.  This script demonstrates the manual steps necessary to build an installation RPM.
