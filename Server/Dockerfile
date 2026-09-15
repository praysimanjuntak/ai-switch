FROM oven/bun:1-alpine
WORKDIR /app
COPY package.json ./
COPY src ./src
COPY public ./public
RUN mkdir -p /data && chown bun:bun /data
ENV AISWITCH_DATA_DIR=/data PORT=8787
VOLUME /data
EXPOSE 8787
USER bun
CMD ["bun", "run", "src/server.ts"]
