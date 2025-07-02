# Use a Node.js base image for better compatibility and smaller size
FROM node:18-slim

# Set working directory inside the container
WORKDIR /app

# Copy the refactored setup script and make it executable
COPY setup_backend.sh .
RUN chmod +x setup_backend.sh

# Run the setup script to generate code, install backend npm dependencies, and PM2
# Note: This script will generate index.js, style.css, script.js, and install npm packages.
# We pass dummy values for DOMAIN, ALLOWED_IP, ADMIN_RAW_PASSWORD during build time.
# These will be overridden by runtime environment variables from docker-compose.
ENV DOMAIN="dummy.domain.com" \
    ALLOWED_IP="127.0.0.1" \
    ADMIN_RAW_PASSWORD="dummy_password" \
    CLEANUP_MONTHS="0"
RUN ./setup_backend.sh

# Expose the port the Node.js app runs on
EXPOSE 3000

# Install cron for cleanup script
RUN apt-get update && apt-get install -y cron && rm -rf /var/lib/apt/lists/*

# Add cron job for cleanup script
# This will run the cleanup script at 00:00 on the 1st day of every CLEANUP_MONTHS interval
# We use a placeholder for CLEANUP_MONTHS here, which will be replaced during build if set,
# or the default 0 will be used, meaning no cron job will be added unless CLEANUP_MONTHS > 0.
# The actual value for cleanup will be read by the cleanup_uploads.js script itself from its generated content.
RUN if [ "$CLEANUP_MONTHS" -gt 0 ]; then \
    echo "0 0 1 */${CLEANUP_MONTHS} * node /app/backend/cleanup_uploads.js >> /var/log/image-bed-cleanup.log 2>&1" | crontab -; \
    fi

# Command to run the Node.js application using PM2 and start cron
# pm2-runtime is designed for Docker environments
CMD ["/bin/bash", "-c", "cron && pm2-runtime start /app/backend/index.js --name image-bed-backend"]
