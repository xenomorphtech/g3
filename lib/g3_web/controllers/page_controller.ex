defmodule G3Web.PageController do
  use G3Web, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
