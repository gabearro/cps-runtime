const path = require('path');

/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    path.join(__dirname, 'workspace.html'),
    path.join(__dirname, 'workspace_app.nim')
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ['"Outfit"', 'system-ui', '-apple-system', 'sans-serif'],
        display: ['"Space Grotesk"', 'system-ui', 'sans-serif'],
        mono: ['"JetBrains Mono"', 'ui-monospace', 'monospace']
      },
      boxShadow: {
        'glass': '0 0 0 1px rgba(255,255,255,0.03) inset, 0 20px 50px -12px rgba(0,0,0,0.4)',
        'glass-lg': '0 0 0 1px rgba(255,255,255,0.04) inset, 0 40px 80px -20px rgba(0,0,0,0.5)',
        'glow-teal': '0 0 32px -4px rgba(45,212,191,0.3)',
        'glow-amber': '0 0 32px -4px rgba(251,191,36,0.25)',
        'glow-violet': '0 0 32px -4px rgba(167,139,250,0.25)',
        'glow-rose': '0 0 32px -4px rgba(251,113,133,0.2)',
        'card-hover': '0 20px 48px -12px rgba(0,0,0,0.4)'
      },
      keyframes: {
        'modal-enter': {
          from: { opacity: '0', transform: 'translateY(16px) scale(0.97)' },
          to: { opacity: '1', transform: 'translateY(0) scale(1)' }
        },
        'fade-in': {
          from: { opacity: '0' },
          to: { opacity: '1' }
        },
        'slide-up': {
          from: { opacity: '0', transform: 'translateY(8px)' },
          to: { opacity: '1', transform: 'translateY(0)' }
        },
        'pulse-ring': {
          '0%, 100%': { opacity: '0.6' },
          '50%': { opacity: '1' }
        },
        'breathe': {
          '0%, 100%': { transform: 'scale(1)', opacity: '0.7' },
          '50%': { transform: 'scale(1.05)', opacity: '1' }
        },
        'shimmer': {
          '0%': { backgroundPosition: '-200% center' },
          '100%': { backgroundPosition: '200% center' }
        }
      },
      animation: {
        'modal-enter': 'modal-enter 280ms cubic-bezier(0.16, 1, 0.3, 1)',
        'fade-in': 'fade-in 400ms ease-out',
        'slide-up': 'slide-up 400ms cubic-bezier(0.16, 1, 0.3, 1)',
        'pulse-ring': 'pulse-ring 2s ease-in-out infinite',
        'breathe': 'breathe 4s ease-in-out infinite',
        'shimmer': 'shimmer 3s ease-in-out infinite'
      }
    }
  },
  plugins: []
};
