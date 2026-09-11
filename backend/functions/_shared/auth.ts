// =============================================================================
// A.R.M.O.R — Phase 2: Auth Helper & Normalization
// File: backend/functions/_shared/auth.ts
// =============================================================================

export const INTERNAL_EMAIL_DOMAIN = 'armor.internal';
export const USERNAME_REGEX = /^[a-z0-9._-]{3,30}$/;

export interface ValidationResult {
  valid: boolean;
  error?: string;
}

/**
 * Deterministically normalizes a username:
 * - Trims leading and trailing whitespace
 * - Converts all characters to lowercase
 */
export function normalizeUsername(rawUsername: string): string {
  if (!rawUsername) return '';
  return rawUsername.trim().toLowerCase();
}

/**
 * Validates a username against system rules:
 * - 3 to 30 characters in length
 * - Only lowercase alphanumeric characters, dots (.), underscores (_), and hyphens (-)
 */
export function validateUsername(username: string): ValidationResult {
  const normalized = normalizeUsername(username);
  if (!normalized) {
    return { valid: false, error: 'Username is required.' };
  }
  if (normalized.length < 3) {
    return { valid: false, error: 'Username must be at least 3 characters long.' };
  }
  if (normalized.length > 30) {
    return { valid: false, error: 'Username cannot exceed 30 characters.' };
  }
  if (!USERNAME_REGEX.test(normalized)) {
    return {
      valid: false,
      error: 'Username may only contain letters, numbers, dots (.), hyphens (-), and underscores (_).',
    };
  }
  return { valid: true };
}

/**
 * Maps a normalized username deterministically to the internal Supabase Auth email.
 * e.g., "raju.hembram" -> "raju.hembram@armor.internal"
 */
export function usernameToInternalEmail(username: string): string {
  const normalized = normalizeUsername(username);
  return `${normalized}@${INTERNAL_EMAIL_DOMAIN}`;
}

/**
 * Validates password rules for registration/login:
 * - Minimum 6 characters required by Supabase Auth
 */
export function validatePassword(password: string): ValidationResult {
  if (!password || password.length < 6) {
    return { valid: false, error: 'Password must be at least 6 characters long.' };
  }
  return { valid: true };
}

/**
 * Validates and casts language selection (default: 'hi')
 */
export function sanitizeLanguage(lang?: string): 'hi' | 'sat' | 'en' {
  if (!lang) return 'hi';
  const clean = lang.trim().toLowerCase();
  if (clean === 'sat' || clean === 'en') return clean;
  return 'hi';
}
