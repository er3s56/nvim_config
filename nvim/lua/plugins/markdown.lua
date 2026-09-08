return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    opts = {
      -- Show markdown as it is written wherever it is not being rendered.
      --
      -- This plugin owns conceallevel for the windows it watches, swapping
      -- between a rendered value and this one, so a window that sets its own
      -- has it taken back. The value it restores is the global 2, which hides
      -- link targets and emphasis markers -- right for reading a document,
      -- wrong everywhere this reverts to. Not rendering means the raw text is
      -- what is wanted: a side-by-side diff, where the edit is as likely to
      -- sit in the hidden half as anywhere else, and the manual toggle, which
      -- is asked for precisely to see the source.
      win_options = { conceallevel = { default = 0 } },
    },
  },
}
