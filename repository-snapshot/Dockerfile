# Use the specified base image
FROM ubuntu:24.04

# Installing dependencies
RUN apt-get update && apt-get install -y \
  coreutils           \
  curl                \
  createrepo-c        \
  cron                \
  debianutils         \
  wget                \
  rsync

# Adding Enableit repo and key
RUN wget https://repos.obmondo.com/packagesign/public/apt/pubkey.gpg -O /etc/apt/keyrings/obmondo_custom.asc
RUN echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/obmondo_custom.asc] https://repos.obmondo.com/packagesign/public/apt noble main" | tee -a /etc/apt/sources.list.d/obmondo_custom.list

# Installing obmondo-scripts-common and obmondo-repository-mirror
RUN apt-get update && apt-get install -y \
  obmondo-scripts-common \
  obmondo-repository-mirror

# Create a crontab file for the scheduled job
RUN echo "0 2 * * 0 /usr/local/bin/snapshot_repo >> /var/log/snapshot_repo.log 2>&1" > /etc/cron.d/snapshot_repo && \
    chmod 0644 /etc/cron.d/snapshot_repo

# Apply cron job and create log file
RUN crontab /etc/cron.d/snapshot_repo && \
    touch /var/log/snapshot_repo.log

# Start the cron service
CMD ["cron", "-f"]
