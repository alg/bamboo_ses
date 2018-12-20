defmodule Bamboo.SesAdapter.RFC2822WithBcc do
  @moduledoc """
  RFC2822 Parser

  Will attempt to render a valid RFC2822 message
  from a `%Message{}` data model.
  """

  import Mail.Message, only: [match_content_type?: 2]
  alias Mail.Encoder
  alias Mail.Message

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @address_types ["From", "To", "Reply-To", "Cc", "Bcc"]

  # https://tools.ietf.org/html/rfc2822#section-3.4.1
  @email_validation_regex ~r/\w+@\w+\.\w+/

  @text_parts_transfer_encoding "base64"

  @doc """
  Renders a message according to the RFC2882 spec
  """
  def render(%Message{multipart: true} = message) do
    message
    |> reorganize
    |> Message.put_header(:mime_version, "1.0")
    |> render_part()
  end

  def render(%Message{} = message),
    do: render_part(message)

  @doc """
  Render an individual part

  An optional function can be passed used during the rendering of each
  individual part
  """
  def render_part(message, render_part_function \\ &render_part/1)
  def render_part(%Message{multipart: true} = message, fun) do
    boundary = Message.get_boundary(message)
    message = Message.put_boundary(message, boundary)

    headers = render_headers(message.headers)
    boundary = "--#{boundary}"

    parts = message.parts
            |> render_parts(fun)
            |> Enum.join("\r\n\r\n#{boundary}\r\n")

    "#{headers}\r\n\r\n#{boundary}\r\n#{parts}\r\n#{boundary}--"
  end
  def render_part(%Message{} = message, _fun) do
    encoded_body = encode(message.body, message)
    "#{render_headers(message.headers)}\r\n\r\n#{encoded_body}"
  end

  def render_parts(parts, fun \\ &render_part/1) when is_list(parts),
    do: Enum.map(parts, &fun.(&1))

  @doc """
  Will render a given header according to the RFC2882 spec
  """
  def render_header(key, value)
  def render_header(key, value) when is_atom(key),
    do: render_header(Atom.to_string(key), value)
  def render_header(key, value) do
    key =
      key
      |> String.replace("_", "-")
      |> String.split("-")
      |> Enum.map(&String.capitalize(&1))
      |> Enum.join("-")

    key <> ": " <> render_header_value(key, value)
  end

  defp render_header_value("Date", date_time),
    do: timestamp_from_erl(date_time)
  defp render_header_value(address_type, addresses) when is_list(addresses) and address_type in @address_types,
    do: addresses |> Enum.map(&render_address(&1)) |> Enum.join(", ")
  defp render_header_value(address_type, address) when address_type in @address_types,
    do: render_address(address)
  defp render_header_value("Content-Transfer-Encoding" = key, value) when is_atom(value) do
    value =
      value
      |> Atom.to_string()
      |> String.replace("_", "-")

    render_header_value(key, value)
  end

  defp render_header_value(_key, [value | subtypes]),
    do: Enum.join([value | render_subtypes(subtypes)], "; ")
  defp render_header_value(key, value),
    do: render_header_value(key, List.wrap(value))

  defp validate_address(address) do
    case Regex.match?(@email_validation_regex, address) do
      true -> address
      false -> raise ArgumentError,
        message: """
        The email address `#{address}` is invalid.
        """
    end
  end

  defp render_address({name, email}), do: ~s("#{name}" <#{validate_address(email)}>)
  defp render_address(email), do: validate_address(email)
  defp render_subtypes([]), do: []
  defp render_subtypes([{key, value} | subtypes]) when is_atom(key),
    do: render_subtypes([{Atom.to_string(key), value} | subtypes])

  defp render_subtypes([{"boundary", value} | subtypes]) do
    [~s(boundary="#{value}") | render_subtypes(subtypes)]
  end
  defp render_subtypes([{key, value} | subtypes]) do
    key = String.replace(key, "_", "-")
    ["#{key}=#{value}" | render_subtypes(subtypes)]
  end

  @doc """
  Will render all headers according to the RFC2882 spec
  """
  def render_headers(headers)
  def render_headers(map) when is_map(map),
    do: map |> Map.to_list |> render_headers()
  def render_headers(list) when is_list(list) do
    list
    |> do_render_headers()
    |> Enum.reverse()
    |> Enum.join("\r\n")
  end

  @doc """
  Builds a RFC2822 timestamp from an Erlang timestamp

  [RFC2822 3.3 - Date and Time Specification](https://tools.ietf.org/html/rfc2822#section-3.3)

  This function always assumes the Erlang timestamp is in Universal time, not Local time
  """
  def timestamp_from_erl({{year, month, day} = date, {hour, minute, second}}) do
    day_name = Enum.at(@days, :calendar.day_of_the_week(date) - 1)
    month_name = Enum.at(@months, month - 1)

    date_part = "#{day_name}, #{day} #{month_name} #{year}"
    time_part = "#{pad(hour)}:#{pad(minute)}:#{pad(second)}"

    date_part <> " " <> time_part <> " +0000"
  end

  defp pad(num),
    do: num
        |> Integer.to_string()
        |> String.pad_leading(2, "0")

  defp do_render_headers([]), do: []
  defp do_render_headers([{_key, nil} | headers]), do: do_render_headers(headers)
  defp do_render_headers([{_key, []} | headers]), do: do_render_headers(headers)
  defp do_render_headers([{key, value} | headers]) when is_binary(value) do
    if String.trim(value) == "" do
      do_render_headers(headers)
    else
      [render_header(key, value) | do_render_headers(headers)]
    end
  end
  defp do_render_headers([{key, value} | headers]) do
    [render_header(key, value) | do_render_headers(headers)]
  end

  defp reorganize(%Message{multipart: true} = message) do
    content_type = Message.get_content_type(message)

    text_parts =
      message.parts
      |> Enum.filter(&(match_content_type?(&1, ~r/text\/(plain|html)/)))
      |> Enum.sort(&(&1 > &2))

    if Enum.any?(text_parts) do
      # Delete text parts
      message =
        text_parts
        |> Enum.reduce(message, &(Message.delete_part(&2, &1)))

      # Update text parts so that their transfer encoding is set to what we want
      updated_text_parts =
        text_parts
        |> Enum.map(&(Message.put_header(&1, :content_transfer_encoding, @text_parts_transfer_encoding)))

      if Message.has_attachment?(message) do
        # Has attachments
        # Mark the top-level part as mixed. It will contain the alternative part with text parts,
        # and the attachments.
        content_type = List.replace_at(content_type, 0, "multipart/mixed")
        message = Message.put_content_type(message, content_type)

        # Create the alternative part to contain the textual parts
        alternative_part =
          Mail.build_multipart()
          |> Message.put_content_type("multipart/alternative")

        # Put updated text parts into the alternative part
        alternative_part =
          updated_text_parts
          |> Enum.reduce(alternative_part, &(Message.put_part(&2, &1)))

        # Insert the alternative with text at the beginning
        put_in(message.parts, List.insert_at(message.parts, 0, alternative_part))
      else
        # Only text parts, no attachments
        content_type = List.replace_at(content_type, 0, "multipart/alternative")
        message = Message.put_content_type(message, content_type)

        # Replace parts with updated text
        put_in(message.parts, updated_text_parts)
      end
    else
      # No text parts, send as is
      message
    end
  end

  defp reorganize(%Message{} = message), do: message

  defp encode(body, message) do
    Encoder.encode(body, Message.get_header(message, "content-transfer-encoding"))
  end
end
