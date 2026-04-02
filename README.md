# 3x-ui + Nginx + Nginx-UI (Docker Bundle)

[RU] Данный проект представляет собой автоматизированное решение для развертывания панели управления 3x-ui вместе с веб-сервером Nginx и графическим интерфейсом для управления конфигурациями Nginx (Nginx-UI) внутри Docker.

[EN] This project is an automated solution for deploying the 3x-ui control panel along with an Nginx web server and a graphical interface for Nginx configuration (Nginx-UI) using Docker.

---

## 🚀 Быстрая установка / Quick Installation

[RU] Вы можете установить проект командой (требуется установленный `curl`):

[EN] You can install the project with a command (`curl` required):

```bash
curl -fLo install.sh https://raw.githubusercontent.com/dail45/docker-3x-ui-nginx-nginx-ui/refs/heads/master/install.sh
chmod +x ./install.sh
sudo bash install.sh
```

---

## ✨ Основные возможности / Features

* **3x-ui**: Современная панель управления Xray (VLESS, VMess, Trojan и др.).
* **Nginx**: Высокопроизводительный веб-сервер для проксирования и TLS.
* **Nginx-UI**: Удобная веб-панель для редактирования конфигов Nginx, управления сертификатами и мониторинга.
* **Docker-based**: Все компоненты изолированы и легко обновляются.
* **Auto-Config**: Скрипт автоматизирует базовую настройку и генерацию необходимых параметров.

## 🛠 Требования / Requirements

- OS: Debian / Ubuntu / CentOS / Arch (Linux)
- Docker & Docker Compose
- Доменное имя (рекомендуется для SSL / Recommended for SSL)

---

## 📖 Использование / Usage

[RU] После завершения работы скрипта `install.sh`, следуйте инструкциям в терминале. Обычно панели доступны по следующим адресам:

[EN] After the `install.sh` script finishes, follow the instructions in your terminal. Usually, the panels are accessible via:

| Service  | Destination                      |
|----------|----------------------------------|
| 3x-ui    | https://your-domain/3x-ui-panel/ |
| Nginx-UI | https://your-domain/nginx-ui/    |

---

## ⚖️ License

Distributed under the MIT License.
