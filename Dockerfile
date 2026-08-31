# 基础镜像：官方 nginx alpine 版（体积小）
FROM 11.0.1.128:30000/nginx:1.27-alpine

# 把静态页面复制进 nginx 默认站点目录
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80
