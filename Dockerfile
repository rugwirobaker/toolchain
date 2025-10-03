# Dockerfile for toolchain.acodechef.dev
# Serves shell installation scripts via nginx

FROM nginx:alpine

# Create web directory
RUN mkdir -p /srv/www

# Copy all shell scripts
COPY install.sh /srv/www/install.sh
COPY zig.sh /srv/www/zig.sh
COPY rust.sh /srv/www/rust.sh
COPY golang.sh /srv/www/golang.sh
COPY bun.sh /srv/www/bun.sh
COPY gadgets.sh /srv/www/gadgets.sh
# COPY README.md /srv/www/README.md

# Generate SHA256 checksums for verification
RUN cd /srv/www && \
    sha256sum *.sh > checksums.txt && \
    cat checksums.txt

# Configure nginx MIME types for shell scripts
RUN printf "types {\n  text/x-shellscript sh;\n  text/markdown md;\n}\n" > /etc/nginx/mime.types.extra

# Create nginx configuration
RUN printf 'server {\n\
    listen 8080;\n\
    server_name _;\n\
    root /srv/www;\n\
    \n\
    # Include custom MIME types\n\
    include /etc/nginx/mime.types.extra;\n\
    include /etc/nginx/mime.types;\n\
    \n\
    # Security headers\n\
    add_header X-Content-Type-Options "nosniff" always;\n\
    add_header X-Frame-Options "DENY" always;\n\
    add_header X-XSS-Protection "1; mode=block" always;\n\
    \n\
    # Serve shell scripts with correct content type\n\
    location ~ \\.sh$ {\n\
    add_header Content-Type "text/x-shellscript; charset=utf-8";\n\
    add_header Cache-Control "public, max-age=3600";\n\
    }\n\
    \n\
    # Serve checksums as plain text\n\
    location = /checksums.txt {\n\
    add_header Content-Type "text/plain; charset=utf-8";\n\
    }\n\
    \n\
    # Serve markdown files\n\
    location ~ \\.md$ {\n\
    add_header Content-Type "text/markdown; charset=utf-8";\n\
    add_header Cache-Control "public, max-age=3600";\n\
    }\n\
    \n\
    # Default location\n\
    location / {\n\
    autoindex on;\n\
    autoindex_exact_size off;\n\
    autoindex_localtime on;\n\
    }\n\
    \n\
    # Health check endpoint\n\
    location /health {\n\
    access_log off;\n\
    return 200 "healthy\\n";\n\
    add_header Content-Type text/plain;\n\
    }\n\
    }\n' > /etc/nginx/conf.d/default.conf

# Set proper permissions
RUN chmod -R a+rX /srv/www

# Expose port
EXPOSE 8080

# Run nginx in foreground
CMD ["nginx", "-g", "daemon off;"]
