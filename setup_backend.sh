#!/bin/bash

# install_image_bed_docker.sh - 一键安装图床 Docker 版脚本
# 这个脚本会自动创建所需的文件和目录，并引导用户完成配置和部署。

set -e

# --- 配置变量 ---
PROJECT_DIR="image-bed-app"
LOG_FILE="/var/log/${PROJECT_DIR}_install.log"

# --- 日志函数 ---
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# --- 检查是否以root用户运行 ---
if [ "$EUID" -ne 0 ]; then
    log_message "错误：请以root用户或使用sudo运行此脚本。"
    exit 1
fi

log_message "--- 图床 Docker 一键安装脚本开始 ---"
log_message "本脚本将自动创建项目文件，并引导你使用 Docker Compose 部署图床应用。"
log_message "所有安装日志将记录在 ${LOG_FILE} 文件中。"

# --- 检查 Docker 和 Docker Compose 是否安装 ---
check_docker_dependencies() {
    log_message ">>> 检查 Docker 是否安装..."
    if ! command -v docker &> /dev/null; then
        log_message "错误：Docker 未安装。请访问 https://docs.docker.com/engine/install/ 安装 Docker。"
        exit 1
    fi
    log_message "Docker 已安装。"

    log_message ">>> 检查 Docker Compose 是否安装 (v2 版本)..."
    if ! command -v docker compose &> /dev/null; then # 注意 v2 版本是 'docker compose'
        log_message "错误：Docker Compose (v2) 未安装。请访问 https://docs.docker.com/compose/install/ 安装 Docker Compose。"
        exit 1
    fi
    log_message "Docker Compose 已安装。"
}

# --- 创建项目目录和文件 ---
create_project_structure() {
    log_message ">>> 正在创建项目目录和文件..."
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"

    mkdir -p backend
    mkdir -p frontend_static

    # 创建 setup_backend.sh
    cat <<'EOF_SETUP_BACKEND' | tr -d '\r' > setup_backend.sh
#!/bin/bash

# setup_backend.sh - This script sets up the Node.js backend for the image bed.
# It is designed to be run inside a Docker container during image build.
# All configurations are read from environment variables.

set -e

LOG_FILE="/var/log/image_bed_backend_setup.log"

# Function to log messages to console and file
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_message "--- Image Bed Backend Setup Script Start ---"
log_message "This script will set up the Node.js backend application."
log_message "All logs will be recorded in ${LOG_FILE}."

# --- Configuration from Environment Variables ---
# DOMAIN: The domain name for the image bed (e.g., example.com)
# ALLOWED_IP: The IP address allowed to upload images (e.g., 1.1.1.1)
# CLEANUP_MONTHS: Interval in months for image cleanup (0 for no cleanup)
# ADMIN_RAW_PASSWORD: Raw password for viewing image list (will be hashed)

# Validate required environment variables
if [ -z "$DOMAIN" ]; then
    log_message "错误：环境变量 DOMAIN 未设置。脚本退出。"
    exit 1
fi
if [ -z "$ALLOWED_IP" ]; then
    log_message "错误：环境变量 ALLOWED_IP 未设置。脚本退出。"
    exit 1
fi
if [ -z "$ADMIN_RAW_PASSWORD" ]; then
    log_message "错误：环境变量 ADMIN_RAW_PASSWORD 未设置。脚本退出。"
    exit 1
fi

# Set default for CLEANUP_MONTHS if not provided or invalid
if [ -z "$CLEANUP_MONTHS" ] || ! [[ "$CLEUP_MONTHS" =~ ^[0-9]+$ ]]; then
    CLEANUP_MONTHS=0
    log_message "CLEANUP_MONTHS 未设置或无效，默认为 0 (不清理)。"
else
    log_message "CLEANUP_MONTHS 设置为 ${CLEANUP_MONTHS}。"
fi

# --- Helper function: Calculate SHA256 Hash (Node.js compatible) ---
calculate_sha256_hash() {
    local password="$1"
    local salt="your_static_salt_for_image_bed" # KEEP THIS CONSISTENT WITH Node.js backend
    
    # Ensure node is available for hashing
    if ! command -v node &> /dev/null
    then
        log_message "错误：'node' 命令在计算密码哈希时不可用。请确保 Node.js 已正确安装。"
        exit 1
    fi
    node -e "const crypto = require('crypto'); console.log(crypto.createHash('sha256').update('$password' + '$salt').digest('hex'));"
}

# Calculate password hash
ADMIN_PASSWORD_HASH=$(calculate_sha256_hash "$ADMIN_RAW_PASSWORD")
log_message "密码哈希已计算。"

# --- Setup Project Directories and Permissions ---
setup_directories_permissions() {
    log_message ">>> Creating project directories /app/backend and /app/frontend..."
    mkdir -p /app/backend >> "$LOG_FILE" 2>&1
    mkdir -p /app/frontend >> "$LOG_FILE" 2>&1
    mkdir -p /app/backend/uploads >> "$LOG_FILE" 2>&1
    
    # In Docker, we typically run as root or a specific user.
    # Permissions might be handled differently or less strictly than on a host.
    # For simplicity, we'll ensure the uploads directory is writable.
    chmod -R 777 /app/backend/uploads >> "$LOG_FILE" 2>&1 || { log_message "错误：设置上传目录权限失败。"; exit 1; }
    log_message "Directories created and permissions set."
}

# --- Deploy Backend Code ---
deploy_backend_code() {
    log_message ">>> Generating backend code (index.js)..."
    # Note: ALLOWED_IP and ADMIN_PASSWORD_HASH will be passed as environment variables
    # when the Node.js application is started by PM2 in the Docker container.
    cat <<EOF > /app/backend/index.js
// index.js (Node.js Express Backend)

// Import necessary modules
const express = require('express');
const multer = require('multer'); // Middleware for handling file uploads
const path = require('path'); // For handling file paths
const fs = require('fs'); // File system module
const cors = require('cors'); // Allow cross-origin requests
const crypto = require('crypto'); // For password hashing

const app = express();
const port = 3000; // Backend service port

// --- Dynamic configuration from environment variables ---
const ALLOWED_IP = process.env.ALLOWED_IP; // IP address allowed to upload
const ADMIN_PASSWORD_HASH = process.env.ADMIN_PASSWORD_HASH; // Hashed admin password

if (!ALLOWED_IP || !ADMIN_PASSWORD_HASH) {
    console.error("Error: ALLOWED_IP or ADMIN_PASSWORD_HASH not set in environment variables. Ensure they are passed when starting the backend.");
    process.exit(1); // Exit if critical configuration is missing
}
console.log("Backend configuration loaded successfully.");

// --- Password hashing function ---
function hashPassword(password) {
    // Use SHA256 hash with a salt (keep consistent with setup_backend.sh)
    const salt = 'your_static_salt_for_image_bed';
    return crypto.createHash('sha256').update(password + salt).digest('hex');
}

// Configure CORS, allowing all origins for simplicity. In production, restrict to your frontend domain.
app.use(cors());
# Parse JSON request bodies for password verification
app.use(express.json());

// Define image upload directory
const uploadDir = path.join(__dirname, 'uploads');

// Check if upload directory exists, create if not
if (!fs.existsSync(uploadDir)) {
    fs.mkdirSync(uploadDir, { recursive: true });
}

// --- IP Whitelist Check Middleware (for /upload endpoint) ---
app.use('/upload', (req, res, next) => {
    // Get client IP address
    // Note: Under Nginx reverse proxy, the real client IP is usually in X-Forwarded-For header
    const clientIp = req.headers['x-forwarded-for']?.split(',')[0].trim() || req.connection.remoteAddress;

    // If IP is not in whitelist, deny upload
    if (clientIp !== ALLOWED_IP) {
        console.warn(`Unauthorized upload attempt from IP: ${clientIp}`);
        return res.status(403).json({ message: `Sorry, your IP address (${clientIp}) is not authorized to upload files.` });
    }
    next(); // Allow request to proceed to the next middleware (multer)
});

// Configure Multer file storage
const storage = multer.diskStorage({
    destination: function (req, file, cb) {
        cb(null, uploadDir); // Store files in the uploads directory
    },
    filename: function (req, file, cb) {
        // Set filename: original filename + timestamp to prevent conflicts
        cb(null, file.fieldname + '-' + Date.now() + path.extname(file.originalname));
    }
});

// Create Multer upload instance
const upload = multer({ storage: storage });

// Serve static files to access uploaded images directly via URL
app.use('/uploads', express.static(uploadDir));

// Define image upload API endpoint
app.post('/upload', upload.single('image'), (req, res) => {
    // 'image' is the name attribute of the file input in the frontend form
    if (!req.file) {
        console.error('File upload failed or no file selected. Request body:', req.body);
        return res.status(400).json({ message: 'No file selected or file upload failed.' });
    }

    // Get full path and filename of the uploaded file
    const imageUrl = `/uploads/${req.file.filename}`;

    // Return success message and image URL
    res.json({
        message: 'Image uploaded successfully!',
        imageUrl: imageUrl // Return relative path, Nginx will handle it
    });
});

// --- New feature: Get image list API (password protected) ---
app.post('/api/list-images', (req, res) => {
    const { password } = req.body;

    if (!password) {
        return res.status(400).json({ message: 'Please provide a password.' });
    }

    // Validate password
    if (hashPassword(password) !== ADMIN_PASSWORD_HASH) {
        console.warn('Unauthorized access attempt to image list from IP:', req.headers['x-forwarded-for']?.split(',')[0].trim() || req.connection.remoteAddress);
        return res.status(401).json({ message: 'Incorrect password.' });
    }

    // If password is correct, read files in the uploads directory
    fs.readdir(uploadDir, (err, files) => {
        if (err) {
            console.error('Failed to read image directory:', err);
            return res.status(500).json({ message: 'Could not retrieve image list.' });
        }

        // Filter out non-image files (based on common image extensions)
        const imageFiles = files.filter(file => {
            const ext = path.extname(file).toLowerCase();
            return ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg'].includes(ext);
        });

        // Return list of image filenames
        res.json({
            message: 'Image list retrieved successfully!',
            images: imageFiles
        });
    });
});

// Simple root path response for testing
app.get('/', (req, res) => {
    res.send('Image Bed Backend Service is running!');
});

// Start the server
app.listen(port, () => {
    console.log(`Image Bed Backend service started on http://localhost:${port}`);
    console.log(`Upload directory: ${uploadDir}`);
});
EOF
    log_message "Backend code index.js generated."

    log_message ">>> Installing backend dependencies (express, multer, cors)..."
    cd /app/backend >> "$LOG_FILE" 2>&1
    npm init -y >> "$LOG_FILE" 2>&1 || { log_message "Error: Backend npm init failed."; exit 1; }
    npm install express multer cors >> "$LOG_FILE" 2>&1 || { log_message "Error: Backend dependency installation failed."; exit 1; }
    log_message "Backend dependencies installed."
}

# --- Deploy Frontend Code ---
deploy_frontend_code() {
    log_message ">>> Generating frontend code (index.html, style.css, script.js)..."
    cat <<EOF > /app/frontend/index.html
<!-- index.html -->
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>我的简易图床</title>
    <!-- Include Tailwind CSS CDN -->
    <script src="https://cdn.tailwindcss.com"></script>
    <!-- Include custom CSS -->
    <link rel="stylesheet" href="style.css">
    <!-- Include Inter font -->
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=swap" rel="stylesheet">
    <style>
        body {
            font-family: 'Inter', sans-serif;
            overflow-x: hidden; /* Prevent horizontal scrolling */
        }
    </style>
</head>
<body class="bg-gradient-to-r from-purple-400 via-pink-500 to-red-500 min-h-screen flex items-center justify-center p-4">

    <!-- Main Upload Interface -->
    <div id="uploadView" class="bg-white p-8 rounded-xl shadow-2xl w-full max-w-md transform transition-all duration-500 hover:scale-105">
        <h1 class="text-3xl font-bold text-center text-gray-800 mb-6">上传你的图片</h1>

        <div class="mb-6">
            <label for="imageUpload" class="block text-gray-700 text-sm font-medium mb-2">选择图片文件:</label>
            <input type="file" id="imageUpload" accept="image/*" class="block w-full text-sm text-gray-900 border border-gray-300 rounded-lg cursor-pointer bg-gray-50 focus:outline-none file:mr-4 file:py-2 file:px-4 file:rounded-full file:border-0 file:text-sm file:font-semibold file:bg-blue-50 file:text-blue-700 hover:file:bg-blue-100">
        </div>

        <button id="uploadButton" class="w-full bg-blue-600 hover:bg-blue-700 text-white font-bold py-3 px-4 rounded-lg shadow-lg transform transition-transform duration-200 hover:scale-100 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-opacity-75">
            上传图片
        </button>

        <div id="messageBox" class="mt-6 p-4 rounded-lg text-sm text-center hidden"></div>

        <div id="imageLinkContainer" class="mt-6 hidden">
            <label class="block text-gray-700 text-sm font-medium mb-2">图片链接:</label>
            <div class="flex items-center space-x-2">
                <input type="text" id="imageLink" readonly class="flex-grow p-3 border border-gray-300 rounded-lg bg-gray-100 text-gray-800 focus:outline-none focus:border-blue-500">
                <button id="copyButton" class="bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg shadow-md transform transition-transform duration-200 hover:scale-100 focus:outline-none focus:ring-2 focus:ring-green-500 focus:ring-opacity-75">
                    复制
                </button>
            </div>
            <img id="uploadedImagePreview" src="" alt="Uploaded Image Preview" class="mt-4 max-w-full h-auto rounded-lg shadow-lg border border-gray-200 hidden">
        </div>

        <button id="showImagesButton" class="w-full bg-indigo-600 hover:bg-indigo-700 text-white font-bold py-3 px-4 rounded-lg shadow-lg transform transition-transform duration-200 hover:scale-100 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-opacity-75 mt-4">
            查看已上传图片
        </button>
    </div>

    <!-- Image List Interface (initially hidden) -->
    <div id="galleryView" class="bg-white p-8 rounded-xl shadow-2xl w-full max-w-3xl transform transition-all duration-500 hidden">
        <h1 class="text-3xl font-bold text-center text-gray-800 mb-6">已上传图片列表</h1>
        
        <!-- Password input -->
        <div id="passwordPrompt" class="mb-6">
            <label for="adminPassword" class="block text-gray-700 text-sm font-medium mb-2">请输入密码查看图片:</label>
            <input type="password" id="adminPassword" class="w-full p-3 border border-gray-300 rounded-lg bg-gray-100 text-gray-800 focus:outline-none focus:border-indigo-500" placeholder="管理员密码">
            <button id="submitPasswordButton" class="w-full bg-indigo-600 hover:bg-indigo-700 text-white font-bold py-2 px-4 rounded-lg shadow-lg transform transition-transform duration-200 hover:scale-100 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-opacity-75 mt-3">
                提交
            </button>
            <div id="passwordMessage" class="mt-3 p-3 rounded-lg text-sm text-center hidden"></div>
        </div>

        <!-- Image list container -->
        <div id="imageGallery" class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-4 hidden">
            <!-- Images will be loaded dynamically here -->
        </div>

        <button id="backToUploadButton" class="w-full bg-gray-500 hover:bg-gray-600 text-white font-bold py-3 px-4 rounded-lg shadow-lg transform transition-transform duration-200 hover:scale-100 focus:outline-none focus:ring-2 focus:ring-gray-400 focus:ring-opacity-75 mt-6">
            返回上传界面
        </button>
    </div>

    <!-- Include custom JavaScript -->
    <script src="script.js"></script>
</body>
</html>
EOF
    log_message "Frontend index.html generated."

    cat <<EOF > /app/frontend/style.css
/* style.css */
/* Custom Tailwind style overrides and additions */

/* Hide default appearance of file input button */
input[type="file"]::-webkit-file-upload-button {
    cursor: pointer;
}

input[type="file"]::file-selector-button {
    cursor: pointer;
}

/* Default styles for message box */
#messageBox.success {
    background-color: #d4edda;
    color: #155724;
    border: 1px solid #c3e6cb;
}

#messageBox.error {
    background-color: #f8d7da;
    color: #721c24;
    border: 1px solid #f5c6cb;
}

/* Styles for password message box */
#passwordMessage.success {
    background-color: #d4edda;
    color: #155724;
    border: 1px solid #c3e6cb;
}

#passwordMessage.error {
    background-color: #f8d7da;
    color: #721c24;
    border: 1px solid #f5c6cb;
}

/* Styles for image thumbnails */
.image-thumbnail {
    width: 100%;
    padding-top: 100%; /* 1:1 Aspect Ratio (creates a square) */
    position: relative;
    border-radius: 0.5rem; /* rounded-lg */
    overflow: hidden; /* ensure content doesn't spill */
    box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06); /* shadow-md */
    transition: transform 0.2s ease-in-out;
}

.image-thumbnail:hover {
    transform: scale(1.05);
}

.image-thumbnail img {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    object-fit: cover; /* Cover the area, cropping if necessary */
    cursor: pointer;
}
EOF
    log_message "Frontend style.css generated."

    cat <<EOF > /app/frontend/script.js
// script.js
document.addEventListener('DOMContentLoaded', () => {
    // --- UI Element References ---
    const uploadView = document.getElementById('uploadView');
    const galleryView = document.getElementById('galleryView');
    const imageUpload = document.getElementById('imageUpload');
    const uploadButton = document.getElementById('uploadButton');
    const messageBox = document.getElementById('messageBox');
    const imageLinkContainer = document.getElementById('imageLinkContainer');
    const imageLink = document.getElementById('imageLink');
    const copyButton = document.getElementById('copyButton');
    const uploadedImagePreview = document.getElementById('uploadedImagePreview');
    const showImagesButton = document.getElementById('showImagesButton');
    const backToUploadButton = document.getElementById('backToUploadButton');
    const adminPasswordInput = document.getElementById('adminPassword');
    const submitPasswordButton = document.getElementById('submitPasswordButton');
    const passwordPrompt = document.getElementById('passwordPrompt');
    const passwordMessage = document.getElementById('passwordMessage');
    const imageGallery = document.getElementById('imageGallery');

    // --- Backend URL (dynamically set by Docker Compose/Nginx) ---
    // This will be the domain or IP where your Nginx proxy is accessible.
    // Since Nginx is proxying, the frontend will make requests to its own origin.
    // For Docker Compose, this will typically be the domain configured for Nginx.
    const backendUrl = window.location.origin;

    // --- Message Display Function ---
    function showMessage(messageElement, message, type) {
        messageElement.textContent = message;
        messageElement.className = `mt-6 p-4 rounded-lg text-sm text-center ${type}`; 
        messageElement.classList.remove('hidden');

        if (type === 'success' || type === 'info') {
            setTimeout(() => {
                messageElement.classList.add('hidden');
            }, 5000);
        }
    }

    // --- View Switching Functions ---
    function showUploadView() {
        uploadView.classList.remove('hidden');
        galleryView.classList.add('hidden');
        // Clear image list and password input
        imageGallery.innerHTML = '';
        adminPasswordInput.value = '';
        passwordPrompt.classList.remove('hidden'); // Show password input
        imageGallery.classList.add('hidden'); // Hide image list
        showMessage(passwordMessage, '', 'hidden'); // Hide password message
    }

    function showGalleryView() {
        uploadView.classList.add('hidden');
        galleryView.classList.remove('hidden');
    }

    // --- Event Listeners ---

    // Upload button click event
    uploadButton.addEventListener('click', async () => {
        const file = imageUpload.files[0];
        if (!file) {
            showMessage(messageBox, '请先选择一个图片文件！', 'error');
            return;
        }

        showMessage(messageBox, '正在上传...', 'info');
        uploadButton.disabled = true;
        imageLinkContainer.classList.add('hidden');
        uploadedImagePreview.classList.add('hidden');

        const formData = new FormData();
        formData.append('image', file);

        try {
            const response = await fetch(`${backendUrl}/upload`, {
                method: 'POST',
                body: formData
            });

            const data = await response.json();

            if (response.ok) {
                showMessage(messageBox, data.message, 'success');
                const fullImageUrl = `${backendUrl}${data.imageUrl}`;
                
                imageLink.value = fullImageUrl;
                uploadedImagePreview.src = fullImageUrl;
                imageLinkContainer.classList.remove('hidden');
                uploadedImagePreview.classList.remove('hidden');
            } else {
                // Backend error message
                showMessage(messageBox, `上传失败: ${data.message || '未知错误'}`, 'error');
            }
        } catch (error) {
            console.error('Error during image upload:', error);
            showMessage(messageBox, '上传图片时发生网络错误，请稍后再试。', 'error');
        } finally {
            uploadButton.disabled = false;
        }
    });

    // Copy button click event
    copyButton.addEventListener('click', () => {
        imageLink.select();
        document.execCommand('copy'); 
        showMessage(messageBox, '图片链接已复制到剪贴板！', 'success');
    });

    // Show image list button click event
    showImagesButton.addEventListener('click', () => {
        showGalleryView();
        adminPasswordInput.focus(); // Auto-focus password input
    });

    // Back to upload interface button click event
    backToUploadButton.addEventListener('click', () => {
        showUploadView();
    });

    // Submit password button click event
    submitPasswordButton.addEventListener('click', async () => {
        const password = adminPasswordInput.value;
        if (!password) {
            showMessage(passwordMessage, '请输入密码。', 'error');
            return;
        }

        showMessage(passwordMessage, '正在验证密码...', 'info');
        submitPasswordButton.disabled = true;

        try {
            const response = await fetch(`${backendUrl}/api/list-images`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ password: password })
            });

            const data = await response.json();

            if (response.ok) {
                showMessage(passwordMessage, data.message, 'success');
                passwordPrompt.classList.add('hidden'); // Hide password input
                imageGallery.classList.remove('hidden'); // Show image list container
                renderImageGallery(data.images); // Render image list
            } else {
                showMessage(passwordMessage, `密码验证失败: ${data.message || '未知错误'}`, 'error');
            }
        } catch (error) {
            console.error('Error fetching image list:', error);
            showMessage(passwordMessage, '获取图片列表时发生网络错误，请稍后再试。', 'error');
        } finally {
            submitPasswordButton.disabled = false;
        }
    });

    // --- Render Image Gallery Function ---
    function renderImageGallery(imageNames) {
        imageGallery.innerHTML = ''; // Clear existing list
        if (imageNames.length === 0) {
            imageGallery.innerHTML = '<p class="text-center text-gray-600">目前没有已上传的图片。</p>';
            return;
        }

        imageNames.forEach(imageName => {
            const fullImageUrl = `${backendUrl}/uploads/${imageName}`;
            
            const imageDiv = document.createElement('div');
            imageDiv.className = 'image-thumbnail'; // Apply square style

            const img = document.createElement('img');
            img.src = fullImageUrl;
            img.alt = imageName;
            img.loading = 'lazy'; // Lazy load images

            // Click image to enlarge or open in new tab
            img.addEventListener('click', () => {
                window.open(fullImageUrl, '_blank');
            });

            imageDiv.appendChild(img);
            imageGallery.appendChild(imageDiv);
        });
    }

    // Initialize to show upload view
    showUploadView();
});
EOF
    log_message "Frontend script.js generated."
    log_message "Frontend code deployed."
}

# --- Set up PM2 to run Node.js application ---
setup_pm2() {
    log_message ">>> Installing PM2 (Node.js process manager)..."
    npm install pm2 -g >> "$LOG_FILE" 2>&1 || { log_message "Error: PM2 installation failed."; exit 1; }
    
    log_message "PM2 installation complete."
}

# --- Setup Scheduled Cleanup Cron Task ---
setup_cleanup_cron() {
    log_message ">>> Deploying cleanup script..."
    
    if [ "$CLEANUP_MONTHS" -eq 0 ]; then
        log_message "No periodic cleanup set, skipping cleanup script configuration."
        return # Exit function
    fi

    # Calculate cleanUpAfterMs (milliseconds)
    local CLEANUP_AFTER_MS=$((CLEANUP_MONTHS * 30 * 24 * 60 * 60 * 1000))

    cat <<EOF > /app/backend/cleanup_uploads.js
// cleanup_uploads.js
const fs = require('fs');
const path = require('path');

const uploadDir = path.join(__dirname, 'uploads');
const cleanUpAfterMs = ${CLEANUP_AFTER_MS}; // Cleanup time (milliseconds) dynamically set by setup script

console.log(`Cleanup script started. Checking directory: ${uploadDir}`);
console.log(`Will delete files created before ${(new Date(Date.now() - cleanUpAfterMs)).toLocaleString()}.`);

fs.readdir(uploadDir, (err, files) => {
    if (err) {
        console.error('Could not read upload directory:', err);
        return;
    }

    files.forEach(file => {
        const filePath = path.join(uploadDir, file);

        fs.stat(filePath, (err, stats) => {
            if (err) {
                console.error(`Could not get file status ${filePath}: `, err);
                return;
            }

            if (stats.isFile() && (Date.now() - stats.birthtimeMs > cleanUpAfterMs)) {
                fs.unlink(filePath, (err) => {
                    if (err) {
                        console.error(`Failed to delete file ${filePath}: `, err);
                    } else {
                        console.log(`Deleted expired file: ${filePath}`);
                    }
                });
            }
        });
    });
    console.log('Cleanup script execution completed.');
});
EOF
    log_message "Cleanup script cleanup_uploads.js generated。"
    log_message "Cleanup script deployment complete。"
}

# --- Main Setup Process ---
log_message "Starting backend setup process..."

# Setup directories and permissions
setup_directories_permissions

# Deploy backend code (index.js) and install npm dependencies
deploy_backend_code

# Deploy frontend code (index.html, style.css, script.js)
deploy_frontend_code

# Install PM2 globally
setup_pm2

# Setup cleanup script (will be run by cron inside the container if enabled)
setup_cleanup_cron

log_message "--- Image Bed Backend Setup Script Finished ---"
log_message "The backend application and frontend static files are ready."
log_message "You can now build your Docker image and run with Docker Compose."

exit 0
EOF_SETUP_BACKEND
    chmod +x setup_backend.sh

    # 创建 backend/Dockerfile
    cat <<'EOF_BACKEND_DOCKERFILE' | tr -d '\r' > backend/Dockerfile
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
EOF_BACKEND_DOCKERFILE

    # 创建 .env.example
    cat <<'EOF_ENV_EXAMPLE' | tr -d '\r' > .env.example
# 你的域名，例如：myimagebed.example.com
DOMAIN=your.domain.com

# 允许上传图片的 IP 地址。
# 如果你想允许所有IP上传 (不推荐用于生产环境)，可以设置为 0.0.0.0
# 如果你只允许特定IP，请填写该IP，例如：192.168.1.100
ALLOWED_IP=your.allowed.ip.address

# 查看图片列表的管理员密码。请设置一个强密码！
ADMIN_RAW_PASSWORD=your_secure_admin_password

# Certbot 注册邮箱，用于接收证书续订通知。
CERTBOT_EMAIL=your_email@example.com

# 定期清理图片的月份间隔。
# 输入 0 或留空表示不清理。例如：3 表示每3个月清理一次。
CLEANUP_MONTHS=3
EOF_ENV_EXAMPLE

    # 创建 docker-compose.yml
    cat <<'EOF_DOCKER_COMPOSE' | tr -d '\r' > docker-compose.yml
version: '3.8'

services:
  # Node.js Backend Service
  backend:
    build:
      context: ./backend # Path to the backend Dockerfile
      dockerfile: Dockerfile
    container_name: image-bed-backend
    # Mount the uploads directory as a named volume for persistence
    volumes:
      - image_bed_uploads:/app/backend/uploads
      - ./frontend_static:/app/frontend # Mount frontend static files from backend container
    environment:
      # These environment variables are crucial for the Node.js backend
      # They will override the dummy values set during Dockerfile build
      - ALLOWED_IP=${ALLOWED_IP}
      - ADMIN_RAW_PASSWORD=${ADMIN_RAW_PASSWORD} # Pass raw password to backend to calculate hash
      - CLEANUP_MONTHS=${CLEANUP_MONTHS}
      - VIRTUAL_HOST=${DOMAIN} # For nginx-proxy to route requests
      - VIRTUAL_PORT=3000 # The port the backend listens on
      - LETSENCRYPT_HOST=${DOMAIN} # For letsencrypt-companion
      - LETSENCRYPT_EMAIL=${CERTBOT_EMAIL} # For letsencrypt-companion
    # Ensure backend starts after proxy is ready (optional, but good practice)
    depends_on:
      - nginx-proxy
      - letsencrypt-companion
    restart: always # Always restart if the container stops

  # Nginx Reverse Proxy Service
  nginx-proxy:
    image: jwilder/nginx-proxy:alpine
    container_name: image-bed-nginx-proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/tmp/docker.sock:ro # Required for nginx-proxy to detect new containers
      - certs:/etc/nginx/certs # Volume for SSL certificates
      - html:/usr/share/nginx/html # Volume for static HTML (e.g., default pages)
      - vhost.d:/etc/nginx/vhost.d # Volume for custom Nginx configurations
      - ./frontend_static:/usr/share/nginx/html/frontend # Mount frontend static files here
    restart: always

  # Let's Encrypt Companion Service for automatic SSL
  letsencrypt-companion:
    image: jrcs/letsencrypt-nginx-proxy-companion
    container_name: image-bed-letsencrypt-companion
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - certs:/etc/nginx/certs
      - html:/usr/share/nginx/html
      - vhost.d:/etc/nginx/vhost.d
    depends_on:
      - nginx-proxy # Ensure proxy is up before companion starts
    restart: always

# Define named volumes for persistence
volumes:
  image_bed_uploads: # For uploaded images
  certs: # For SSL certificates managed by letsencrypt-companion
  html: # For nginx-proxy's internal use (e.g., challenge files)
  vhost.d: # For nginx-proxy's custom vhost configurations

# Define a network (optional, but good for explicit control)
networks:
  default:
    driver: bridge
EOF_DOCKER_COMPOSE

    log_message "项目结构和文件创建完成。"
}

# --- 主安装流程 ---
main_install_process() {
    log_message "开始执行主安装流程..."

    check_docker_dependencies
    create_project_structure

    echo ""
    log_message "重要提示：请配置环境变量！"
    log_message "已在当前目录 (${PROJECT_DIR}) 下生成 .env.example 文件。"
    log_message "请复制该文件为 .env，并根据你的实际情况修改其中的配置项："
    log_message "  DOMAIN：你的域名（例如：myimagebed.example.com）"
    log_message "  ALLOWED_IP：允许上传图片的 IP 地址"
    log_message "  ADMIN_RAW_PASSWORD：查看图片列表的管理员密码"
    log_message "  CERTBOT_EMAIL：Certbot 注册邮箱"
    log_message "  CLEANUP_MONTHS：定期清理图片的月份间隔"
    echo ""
    echo "请在继续之前，务必完成 .env 文件的配置！"
    echo "你可以使用 'nano ${PROJECT_DIR}/.env' 或 'vi ${PROJECT_DIR}/.env' 进行编辑。"
    echo ""
    read -p "配置完成后，按 Enter 键继续..."

    # 复制 .env.example 到 .env (如果用户没有手动创建)
    if [ ! -f "${PROJECT_DIR}/.env" ]; then
        log_message "未检测到 .env 文件，将从 .env.example 复制一份。"
        cp "${PROJECT_DIR}/.env.example" "${PROJECT_DIR}/.env"
    fi

    log_message ">>> 正在启动 Docker Compose 服务..."
    cd "$PROJECT_DIR"
    docker compose up -d --build >> "$LOG_FILE" 2>&1 || { log_message "错误：Docker Compose 启动失败。请检查日志文件或手动运行 'docker compose up' 调试。"; exit 1; }
    log_message "Docker Compose 服务已成功启动！"

    echo ""
    log_message "--- 图床 Docker 版部署成功！---"
    log_message "请访问你在 .env 文件中配置的域名 (例如：https://your.domain.com) 来访问图床。"
    log_message "请务必牢记你的管理员密码！"
    log_message "你可以使用 'docker compose ps' 查看容器状态。"
    log_message "你可以使用 'docker compose logs' 查看服务日志。"
    log_message "安装脚本的完整日志位于 ${LOG_FILE}"
    echo ""
}

# --- 执行主流程 ---
main_install_process

exit 0
