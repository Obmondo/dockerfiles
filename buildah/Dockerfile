FROM quay.io/buildah/stable:v1.32.0

RUN touch /etc/subgid /etc/subuid \
&& chmod g=u /etc/subgid /etc/subuid /etc/passwd \
&& echo build:10000:65536 > /etc/subuid \
&& echo build:10000:65536 > /etc/subgid

# Use chroot since the default runc does not work when running rootless
RUN echo "export BUILDAH_ISOLATION=chroot" >> /home/build/.bashrc

# Use VFS since fuse does not work
RUN mkdir -p /home/build/.config/containers \
&& (echo '[storage]';echo 'driver = "vfs"') > /home/build/.config/containers/storage.conf

# The buildah container will run as `build` user
USER build
WORKDIR /home/build
