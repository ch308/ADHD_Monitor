const fs = require('fs');
const path = require('path');

const dirsToRemove = [
    'C:\\etc\\adhd_monitor\\ESP32-S3-LCD-1.47B\\build',
    'C:\\etc\\adhd_monitor\\xiaozhi-esp32-2.2.4\\build'
];

function rimraf(dir) {
    if (!fs.existsSync(dir)) {
        console.log('Already clean:', dir);
        return;
    }
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
        const full = path.join(dir, entry.name);
        try {
            if (entry.isDirectory()) {
                rimraf(full);
            } else {
                fs.unlinkSync(full);
            }
        } catch (e) {
            // retry with different approach
            try {
                if (entry.isDirectory()) {
                    fs.rmdirSync(full, { recursive: true });
                } else {
                    fs.rmSync(full, { force: true });
                }
            } catch (e2) {
                console.error('Failed to remove:', full, e2.message);
            }
        }
    }
    fs.rmdirSync(dir);
    console.log('Removed:', dir);
}

for (const dir of dirsToRemove) {
    rimraf(dir);
}
console.log('Done.');
