FROM nginx:1.27-alpine

# Copy our static page and nginx config into the image
COPY index.html /usr/share/nginx/html/index.html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
# nginx:alpine's default CMD already starts nginx in foreground, so we don't need one