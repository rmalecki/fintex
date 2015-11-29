defmodule FinTex.Command.Sequencer do
  @moduledoc false

  alias FinTex.Command.AbstractCommand
  alias FinTex.Connection.HTTPBody
  alias FinTex.Connection.HTTPClient
  alias FinTex.Model.Dialog

  use AbstractCommand
  import Supervisor.Spec
  require Record

  @type t :: %__MODULE__{
    dialog: term,
    options: list
  }

  defstruct [
    dialog: nil,
    options: nil
  ]


  def new(client_system_id \\ "0", bank = %{}, credentials \\ nil, options)
  when is_list(options) do
    {_, _, _} = :random.seed

    d = cond do 
      credentials -> Dialog.new(client_system_id, bank, credentials.login, credentials.client_id, credentials.pin)
      true        -> Dialog.new(client_system_id, bank)
    end

    ssl_options = Application.get_env(:fintex, :ssl_options, [])
    |> Dict.merge(Dict.get(options, :ssl_options, []))

    ibrowse = Application.get_env(:fintex, :ibrowse, [])
    |> Dict.merge(Dict.get(options, :ibrowse, []))

    timeout = nil
    || Dict.get(options, :http_options, []) |> Dict.get(:timeout)
    || Application.get_env(:fintex, :http_options, []) |> Dict.get(:timeout)

    options = options
    |> Dict.merge([ssl_options: ssl_options, ibrowse: ibrowse, timeout: timeout])

    %__MODULE__{dialog: d, options: options}
  end


  def call_http(%__MODULE__{dialog: %Dialog{bank: bank} = d, options: options}, request_segments, opts \\ []) do
    request_segments = request_segments |> Enum.map(&create(&1, d))
    request_segments |> inspect(binaries: :as_strings, pretty: true, limit: :infinity) |> debug
    body = request_segments |> HTTPBody.encode_body(d)
    options = Dict.merge(options, opts)

    children = [
      worker(HTTPClient, [bank.url, body, options], restart: :temporary)
    ]
    {:ok, supervisor_pid} = Supervisor.start_link(children, strategy: :simple_one_for_one, shutdown: options[:timeout])

    result =
    try do
      {:ok, worker_pid} = Supervisor.start_child(supervisor_pid, [])
      case options[:ignore_response] do
        true -> :ok
        _ -> worker_pid |> HTTPClient.fetch(timeout: options[:timeout])
      end
    catch type, error ->
      {:error, {type, error}}
    end

    true = Process.exit(supervisor_pid, :normal)

    case result do
      {:ok, response_body} ->
        response = HTTPBody.decode_body(response_body)
        response |> inspect(pretty: true, limit: :infinity) |> debug
        Stream.concat(response[:HIRMG], response[:HIRMS]) |> check_messages_for_errors
        {:ok, response}
      :ok ->
        :ok
      {:error, msg} ->
        raise FinTex.Error, reason: msg
    end
  end


  def dialog(%__MODULE__{dialog: d}) do
    d
  end


  def update(state = %__MODULE__{dialog: d}, client_system_id)
  when is_binary(client_system_id) do
    d = d |> Dialog.update(client_system_id)
    %__MODULE__{state | dialog: d}
  end


  def update(state = %__MODULE__{dialog: d}, dialog_id, bpd \\ nil, pintan \\ nil, supported_tan_schemes \\ nil)
  when is_binary(dialog_id) do
    d = d |> Dialog.update(dialog_id, bpd, pintan, supported_tan_schemes)
    %__MODULE__{state | dialog: d}
  end


  def inc(state = %__MODULE__{dialog: d}) do
    d = d |> Dialog.inc
    %__MODULE__{state | dialog: d}
  end


  def reset(state = %__MODULE__{dialog: d}, tan_scheme_sec_func) do
    d = d |> Dialog.reset(tan_scheme_sec_func)
    %__MODULE__{state | dialog: d}
  end
end
