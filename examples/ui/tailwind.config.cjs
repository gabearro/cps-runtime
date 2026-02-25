const path = require('path');

/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    path.join(__dirname, 'test_spa.html'),
    path.join(__dirname, 'test_spa_app.nim')
  ],
  theme: {
    extend: {
      fontFamily: {
        display: ['"Sora"', 'ui-sans-serif', 'system-ui', 'sans-serif']
      },
      boxShadow: {
        glow: '0 0 0 1px rgba(15,118,110,0.24), 0 8px 30px rgba(15,118,110,0.25)'
      },
      animation: {
        'float-soft': 'float-soft 6s ease-in-out infinite'
      },
      keyframes: {
        'float-soft': {
          '0%, 100%': { transform: 'translateY(0px)' },
          '50%': { transform: 'translateY(-6px)' }
        }
      }
    }
  },
  plugins: []
};
