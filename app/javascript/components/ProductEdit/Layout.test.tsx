import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Layout } from './Layout';

// Mock the feature flag module
jest.mock('../../utils/features', () => ({
  featureEnabled: jest.fn(),
}));

// Mock the save function
const mockHandleSave = jest.fn();

describe('ProductEdit Layout Keyboard Shortcuts', () => {
  let featureEnabled: jest.Mock;

  beforeEach(() => {
    jest.clearAllMocks();
    featureEnabled = require('../../utils/features').featureEnabled;
    // Reset DOM state
    document.body.innerHTML = '';
  });

  describe('Cmd/Ctrl+S keyboard shortcut', () => {
    describe('when feature flag is enabled', () => {
      beforeEach(() => {
        featureEnabled.mockReturnValue(true);
      });

      it('should trigger save on Meta+S (Mac)', () => {
        const { container } = render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={<div>Content</div>}
          />
        );

        // Simulate Meta+S (Cmd+S on Mac)
        fireEvent.keyDown(window, {
          key: 's',
          code: 'KeyS',
          metaKey: true,
          ctrlKey: false,
          preventDefault: jest.fn(),
        });

        expect(mockHandleSave).toHaveBeenCalledTimes(1);
      });

      it('should trigger save on Ctrl+S (Windows/Linux)', () => {
        const { container } = render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={<div>Content</div>}
          />
        );

        // Simulate Ctrl+S
        fireEvent.keyDown(window, {
          key: 's',
          code: 'KeyS',
          metaKey: false,
          ctrlKey: true,
          preventDefault: jest.fn(),
        });

        expect(mockHandleSave).toHaveBeenCalledTimes(1);
      });

      it('should not trigger save when typing in input field', () => {
        const { container } = render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={
              <div>
                <input type="text" id="test-input" />
              </div>
            }
          />
        );

        const input = screen.getByRole('textbox');
        input.focus();

        // Simulate Ctrl+S while focused on input
        fireEvent.keyDown(window, {
          key: 's',
          code: 'KeyS',
          ctrlKey: true,
          metaKey: false,
          preventDefault: jest.fn(),
        });

        expect(mockHandleSave).not.toHaveBeenCalled();
      });

      it('should not trigger save when typing in textarea', () => {
        const { container } = render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={
              <div>
                <textarea id="test-textarea" />
              </div>
            }
          />
        );

        const textarea = container.querySelector('textarea');
        textarea?.focus();

        // Simulate Meta+S while focused on textarea
        fireEvent.keyDown(window, {
          key: 's',
          code: 'KeyS',
          metaKey: true,
          ctrlKey: false,
          preventDefault: jest.fn(),
        });

        expect(mockHandleSave).not.toHaveBeenCalled();
      });

      it('should not trigger save when typing in contenteditable element', () => {
        const { container } = render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={
              <div>
                <div contentEditable="true" id="editor">
                  Editable content
                </div>
              </div>
            }
          />
        );

        const editableDiv = container.querySelector('[contenteditable="true"]');
        editableDiv?.focus();

        // Simulate Ctrl+S while focused on contenteditable
        fireEvent.keyDown(window, {
          key: 's',
          code: 'KeyS',
          ctrlKey: true,
          metaKey: false,
          preventDefault: jest.fn(),
        });

        expect(mockHandleSave).not.toHaveBeenCalled();
      });

      it('should always prevent default browser save dialog', () => {
        const preventDefault = jest.fn();
        
        render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={<div>Content</div>}
          />
        );

        // Simulate Ctrl+S
        fireEvent.keyDown(window, {
          key: 's',
          code: 'KeyS',
          ctrlKey: true,
          metaKey: false,
          preventDefault,
        });

        expect(preventDefault).toHaveBeenCalledTimes(1);
      });

      it('should handle both Meta and Ctrl keys simultaneously', () => {
        render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={<div>Content</div>}
          />
        );

        // Simulate both Meta+Ctrl+S (edge case)
        fireEvent.keyDown(window, {
          key: 's',
          code: 'KeyS',
          metaKey: true,
          ctrlKey: true,
          preventDefault: jest.fn(),
        });

        // Should still trigger save only once
        expect(mockHandleSave).toHaveBeenCalledTimes(1);
      });

      it('should not trigger save with other modifier keys', () => {
        render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={<div>Content</div>}
          />
        );

        // Test Alt+S
        fireEvent.keyDown(window, {
          key: 's',
          code: 'KeyS',
          altKey: true,
          metaKey: false,
          ctrlKey: false,
          preventDefault: jest.fn(),
        });

        expect(mockHandleSave).not.toHaveBeenCalled();

        // Test Shift+S
        fireEvent.keyDown(window, {
          key: 'S',
          code: 'KeyS',
          shiftKey: true,
          metaKey: false,
          ctrlKey: false,
          preventDefault: jest.fn(),
        });

        expect(mockHandleSave).not.toHaveBeenCalled();
      });

      it('should not trigger save with different keys', () => {
        render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={<div>Content</div>}
          />
        );

        // Test Ctrl+A
        fireEvent.keyDown(window, {
          key: 'a',
          code: 'KeyA',
          ctrlKey: true,
          preventDefault: jest.fn(),
        });

        expect(mockHandleSave).not.toHaveBeenCalled();

        // Test Meta+P
        fireEvent.keyDown(window, {
          key: 'p',
          code: 'KeyP',
          metaKey: true,
          preventDefault: jest.fn(),
        });

        expect(mockHandleSave).not.toHaveBeenCalled();
      });

      it('should cleanup event listener on unmount', () => {
        const removeEventListenerSpy = jest.spyOn(window, 'removeEventListener');
        
        const { unmount } = render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={<div>Content</div>}
          />
        );

        unmount();

        expect(removeEventListenerSpy).toHaveBeenCalledWith('keydown', expect.any(Function));
        removeEventListenerSpy.mockRestore();
      });
    });

    describe('when feature flag is disabled', () => {
      beforeEach(() => {
        featureEnabled.mockReturnValue(false);
      });

      it('should not trigger save on Cmd+S', () => {
        render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={<div>Content</div>}
          />
        );

        fireEvent.keyDown(window, {
          key: 's',
          code: 'KeyS',
          metaKey: true,
          preventDefault: jest.fn(),
        });

        expect(mockHandleSave).not.toHaveBeenCalled();
      });

      it('should not trigger save on Ctrl+S', () => {
        render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={<div>Content</div>}
          />
        );

        fireEvent.keyDown(window, {
          key: 's',
          code: 'KeyS',
          ctrlKey: true,
          preventDefault: jest.fn(),
        });

        expect(mockHandleSave).not.toHaveBeenCalled();
      });

      it('should not add event listener', () => {
        const addEventListenerSpy = jest.spyOn(window, 'addEventListener');
        
        render(
          <Layout 
            handleSave={mockHandleSave}
            saveButtonText="Save"
            children={<div>Content</div>}
          />
        );

        // Check that no keydown listener was added
        const keydownListeners = addEventListenerSpy.mock.calls.filter(
          call => call[0] === 'keydown'
        );
        expect(keydownListeners).toHaveLength(0);

        addEventListenerSpy.mockRestore();
      });
    });
  });

  describe('aria-keyshortcuts attribute', () => {
    it('should add aria-keyshortcuts to save button when feature is enabled', () => {
      featureEnabled.mockReturnValue(true);
      
      render(
        <Layout 
          handleSave={mockHandleSave}
          saveButtonText="Save"
          children={<div>Content</div>}
        />
      );

      const saveButton = screen.getByText('Save');
      expect(saveButton).toHaveAttribute('aria-keyshortcuts');
      
      const ariaValue = saveButton.getAttribute('aria-keyshortcuts');
      expect(ariaValue).toMatch(/Meta\+S|Ctrl\+S/);
    });

    it('should not add aria-keyshortcuts when feature is disabled', () => {
      featureEnabled.mockReturnValue(false);
      
      render(
        <Layout 
          handleSave={mockHandleSave}
          saveButtonText="Save"
          children={<div>Content</div>}
        />
      );

      const saveButton = screen.getByText('Save');
      expect(saveButton).not.toHaveAttribute('aria-keyshortcuts');
    });

    it('should use platform-appropriate aria-keyshortcuts value', () => {
      featureEnabled.mockReturnValue(true);
      
      // Mock navigator.platform for Mac
      Object.defineProperty(navigator, 'platform', {
        value: 'MacIntel',
        writable: true,
      });

      const { rerender } = render(
        <Layout 
          handleSave={mockHandleSave}
          saveButtonText="Save"
          children={<div>Content</div>}
        />
      );

      let saveButton = screen.getByText('Save');
      expect(saveButton.getAttribute('aria-keyshortcuts')).toContain('Meta+S');

      // Mock navigator.platform for Windows
      Object.defineProperty(navigator, 'platform', {
        value: 'Win32',
        writable: true,
      });

      rerender(
        <Layout 
          handleSave={mockHandleSave}
          saveButtonText="Save"
          children={<div>Content</div>}
        />
      );

      saveButton = screen.getByText('Save');
      expect(saveButton.getAttribute('aria-keyshortcuts')).toContain('Ctrl+S');
    });
  });

  describe('Save button interaction', () => {
    it('should call handleSave when save button is clicked', async () => {
      featureEnabled.mockReturnValue(true);
      
      render(
        <Layout 
          handleSave={mockHandleSave}
          saveButtonText="Save Product"
          children={<div>Content</div>}
        />
      );

      const saveButton = screen.getByText('Save Product');
      await userEvent.click(saveButton);

      expect(mockHandleSave).toHaveBeenCalledTimes(1);
    });

    it('should disable save button when saving', () => {
      featureEnabled.mockReturnValue(true);
      
      render(
        <Layout 
          handleSave={mockHandleSave}
          saveButtonText="Save"
          saving={true}
          children={<div>Content</div>}
        />
      );

      const saveButton = screen.getByText('Save');
      expect(saveButton).toBeDisabled();
    });

    it('should show saving text when saving', () => {
      featureEnabled.mockReturnValue(true);
      
      render(
        <Layout 
          handleSave={mockHandleSave}
          saveButtonText="Save"
          savingButtonText="Saving..."
          saving={true}
          children={<div>Content</div>}
        />
      );

      expect(screen.getByText('Saving...')).toBeInTheDocument();
    });
  });

  describe('Focus behavior', () => {
    it('should detect focus in nested input elements', () => {
      featureEnabled.mockReturnValue(true);
      
      render(
        <Layout 
          handleSave={mockHandleSave}
          saveButtonText="Save"
          children={
            <div>
              <div>
                <form>
                  <input type="text" id="nested-input" />
                </form>
              </div>
            </div>
          }
        />
      );

      const input = screen.getByRole('textbox');
      input.focus();

      fireEvent.keyDown(window, {
        key: 's',
        code: 'KeyS',
        ctrlKey: true,
        preventDefault: jest.fn(),
      });

      expect(mockHandleSave).not.toHaveBeenCalled();
    });

    it('should handle focus changes correctly', () => {
      featureEnabled.mockReturnValue(true);
      
      render(
        <Layout 
          handleSave={mockHandleSave}
          saveButtonText="Save"
          children={
            <div>
              <input type="text" id="input" />
              <button id="button">Click me</button>
            </div>
          }
        />
      );

      const input = screen.getByRole('textbox');
      const button = screen.getByText('Click me');

      // Focus on input - should not save
      input.focus();
      fireEvent.keyDown(window, {
        key: 's',
        code: 'KeyS',
        ctrlKey: true,
        preventDefault: jest.fn(),
      });
      expect(mockHandleSave).not.toHaveBeenCalled();

      // Focus on button - should save
      button.focus();
      fireEvent.keyDown(window, {
        key: 's',
        code: 'KeyS',
        ctrlKey: true,
        preventDefault: jest.fn(),
      });
      expect(mockHandleSave).toHaveBeenCalledTimes(1);
    });
  });
});
