# basis-vdi-2.4.3
all configs for projects 
1. Создайте директорию проекта и поместите в неё следующие файлы:
 basis-vdi-client-v2.4.3/
   ├── Dockerfile
   ├── start_vdi-client-2.4.3.sh
   ├── vdi-client-2.4.3-r278.n496a10.common.x86_64.rpm
   └── vms-vdi-env-python3-3.9.19-alt10basis1.x86_64.rpm

2. docker build -t basis-vdi-client:2.4.3 .
3. chmod +x start_vdi-client-2.4.3.sh
   ./start_vdi-client-2.4.3.sh
