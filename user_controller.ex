defmodule TimetrackerAdmin.V2.UserController do
  use TimetrackerAdmin.Web, :controller
  require IEx

  alias TimetrackerAdmin.TimeQ
  alias TimetrackerAdmin.TimesCalc

  alias TimetrackerAdmin.User
  alias TimetrackerAdmin.UserProject
  alias TimetrackerAdmin.UserOrganization
  alias TimetrackerAdmin.UserGroup
  alias TimetrackerAdmin.Group
  alias TimetrackerAdmin.Repo
  alias TimetrackerAdmin.Log
  alias TimetrackerAdmin.Task
  alias TimetrackerAdmin.Organization
  alias TimetrackerAdmin.Project
  alias TimetrackerAdmin.Activity
  alias TimetrackerAdmin.UserSetting
  alias TimetrackerAdmin.Setting
  alias TimetrackerAdmin.TimeUnit
  alias TimetrackerAdmin.Session
  alias TimetrackerAdmin.Timezone, as: Ttimezone
  import Ecto.Query, only: [from: 2]
  alias Comeonin.Bcrypt
  require Logger
  use Timex
  alias UUID

  alias TimetrackerAdmin.AmazonS3

  #plug :action

  def index(conn, _params) do

    case _params["type"] do
      "org" ->
        organization = get_session(conn, :current_organization)
        users = User.get_users_organization(organization.id)
      _ ->
        users = Repo.all(User)
    end

    render conn, :index, users: users
  end

  def show(conn, %{"id" => id}) do
    task = Repo.get(Task, id)
    render conn, :show, task: task
  end

  def create(conn, %{"task" => params}) do
    #IEx.pry
    changeset = Task.changeset(%Task{}, params)

    if changeset.valid? do
      task = Repo.insert(changeset)
      render conn, :show, task: task
    end
  end

  def update(conn, %{"id" => id, "task" => params}) do
    task = Repo.get(Task, id)
    changeset = Task.changeset(task, params)

    if changeset.valid? do
      task = Repo.update(changeset)
      render conn, :show, task: task
    end
  end

  def delete(conn, %{"id" => id}) do
    task = Repo.get(Task, id)
    task = Repo.delete(task)
    render conn, :show, task: task
  end

  def create_user(conn, _params) do
    org = get_session(conn, :current_organization)
    vl= false
    #Logger.info "#{_params}"
    param = _params["array"]

    if Repo.all(from u in User, where: u.username == ^param["username"]) == [] do
      if Repo.all(from u in User, where: u.email == ^param["email"]) == [] do
        user = User.changeset(%User{}, %{"email" => param["email"], "first_name" => param["name"], "last_name" => param["lastname"], "username" => param["username"]})
        user = Ecto.Changeset.put_change(user, :password, Bcrypt.hashpwsalt(param["password"]))
        user = Ecto.Changeset.put_change(user, :timezone_id, _params["timezone"])

        if user.valid? do
          Repo.insert(user)
          new_user = Repo.one(from u in User, where: u.email == ^param["email"], select: u.id)

          role_member = Repo.one(from r in Group, where: r.name == "Member", select: r)
            chgset = UserOrganization.changeset(%UserOrganization{}, %{"user_id" => new_user, "organization_id" => org.id})
              if chgset.valid? do
                Repo.insert(chgset)
              end
            chgset = UserGroup.changeset(%UserGroup{}, %{"user_id" => new_user, "group_id" => role_member.id})
              if chgset.valid? do
                Repo.insert(chgset)
              end
            su = Repo.one(from s in Setting, where: s.setting_name == "Screenshot Time", select: s.id)
            tm = Repo.one(from tm in TimeUnit, where: tm.name == "Minute", select: tm.id)
            userSetting =  Repo.insert(%UserSetting{user_id: new_user, setting_id: su, value: "15", time_unit_id: tm})
            vl = true
        end

      else
        user = %{success: false, message: "Email already exists"}
        render conn, :menssage, user: user
      end
    else
      user = %{success: false, message: "Username already exists"}
      render conn, :menssage, user: user
    end

     if vl == true do
      link = "http://perfq.com/"
      :gen_smtp_client.send({to_string(param["email"]), [to_string(param["email"])],'Subject: Registro\r\nFrom: PerfQ.com \r\nTo: \r\n\r\nYou have been successfully registered in the Systrix perfq organization.
      Username: ' ++ String.to_char_list(param["username"])  ++ '
      Password: ' ++ String.to_char_list(param["password"])  ++ '
      If you are interested please follow this link: '++ String.to_char_list(link) ++''},
      [{:relay, to_string(System.get_env("MAIL_RELAY"))}, {:username, to_string(System.get_env("MAIL_USERNAME"))}, {:password, to_string(System.get_env("MAIL_PASSWORD"))}, {:tls, :always}, {:port, 587}])
      Logger.info "Email sent"
     end
    user = %{success: true, message: "User created succesfully. Confirmation sent to email"}
    render conn, :menssage, user: user
  end

  def up_user(conn, %{"id" => id} ) do
    Logger.info "#{id}"
      user_id = get_session(conn, :current_user)
      us = Repo.one(from u in User, join: t in Ttimezone, on: t.id == u.timezone_id, where: u.id ==^id,
      select: %{first_name: u.first_name, last_name: u.last_name, username: u.username, email: u.email, password: u.password, verify: u.password, avatar: u.avatar, id_timezone: u.timezone_id,
      name_timezone: t.name})

      user = %{first_name: us.first_name, last_name: us.last_name, username: us.username, email: us.email, idsession: user_id.id, password: us.password, verify: us.password, avatar: us.avatar, id_timezone: us.id_timezone, name_timezone: us.name_timezone}
      render conn, :menssage, user: user
  end

  def save_avatar(avatar, user_id)do
      # IEx.pry
      # "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASA...
      [data, type, base, code ] = String.split(avatar, [";", ",", ":"])

      file_name = "avatar_#{user_id}.#{AmazonS3.extension(type)}"
      path = "priv/tmp/"

      { :ok, file_path} = AmazonS3.base64toFile( "#{path}#{file_name}",code)
      {:ok, thumbnail_name} = AmazonS3.create_thumbnail( path, file_name, "200x200")

      sent = AmazonS3.sendS3( "#{path}#{thumbnail_name}", file_name )

      case sent do
          {:ok, url, msg} ->
              IO.puts(" --- avatar guardado --- #{file_name}, #{msg}")

              File.rm("#{path}#{file_name}") # Eliminar archivo
              File.rm("#{path}#{thumbnail_name}") # Eliminar thumbnaiL
              "#{url}?rm=#{AmazonS3.plain_date(Ecto.DateTime.utc)}"
          {:error, _} ->
              "/static/img/no-avatar.png"
      end


  end

  def update_user(conn, _params) do
    #Logger.info "#{id}"
    param = _params["array"]
    id = _params["id"]
    z_id = _params["timezone"]
    Logger.info "#{z_id}"
    us = Repo.get(User, id)

    changeset = User.changeset(us, param)
    |> Ecto.Changeset.put_change :timezone_id, z_id

    if _params["changeImg"] == true do
      changeset = Ecto.Changeset.put_change(changeset, :avatar, save_avatar(_params["avatar"], id))
      # |> Ecto.Changeset.put_change :avatar, save_avatar(_params["avatar"], id)
    end

    if _params["pass"] == true do
      changeset = Ecto.Changeset.put_change(changeset, :password, Bcrypt.hashpwsalt(param["password"]))
    end

    if changeset.valid? do
      Repo.update(changeset)
    end
    user = %{success: true, message: "User updated succesfully."}
    render conn, :menssage, user: user
  end

  def remov_user(conn, %{"id" => id}) do
    org = get_session(conn, :current_organization)
    rem = Repo.one(from(u in UserOrganization, where: u.organization_id == ^org.id,
    where: u.user_id == ^id))
    Repo.delete(rem)

    user = %{success: true, message: "User removed succesfully."}
    render conn, :menssage, user: user
  end

  def user_list(org_id, type_list \\ :all)do
    u = from(u in User,
      join: uo in UserOrganization, on: uo.user_id == u.id,
      where: uo.organization_id == ^org_id,
      select: %{
        id: u.id,
        first_name: u.first_name,
        last_name: u.last_name,
        avatar: u.avatar,
        email: u.email,
        inserted_at: u.inserted_at
      }
    )
    case type_list do
      _ ->  Repo.all(u)
    end
  end

  #def users_index(conn, _params)do
  #  org = get_session(conn, :current_organization)
  #  users = user_list(org.id, :all)

  #  o = Enum.map(users, fn u ->
  #    {t, _} = TimesCalc.onlineTime( TimeQ.today(user_id.timezone), [us.id], all_proj)
  #    {time_h, time_m} = {t.time_h, t.time_m}

  #    {t7, _} = TimesCalc.onlineTime( TimeQ.last7days(user_id.timezone), [us.id], all_proj)
  #    {times_h, times_m} = {t7.time_h, t7.time_m}
  #  end)
  #end

  def users_all(conn, _params) do
    local = Ecto.DateTime.utc

    user_id = get_session(conn, :current_user)

    org = get_session(conn, :current_organization)
    all_proj = TimesCalc.project_list(org.id)
    lusers = from u in User, join: uo in UserOrganization,
    on: uo.user_id == u.id, where: uo.organization_id == ^org.id,
      select: %{:id => u.id, :org => uo.organization_id, :first_name => u.first_name, :last_name => u.last_name, :avatar => u.avatar, :email => u.email, :inst => u.inserted_at}
      lusers = Repo.all(lusers)

      userss = Enum.map(lusers, fn(us) ->
        query = from l in Log, join: r in UserOrganization, on: r.user_id == ^us.id,
        where: r.organization_id == ^us.org,
        where: l.user_id == ^us.id,
        where: l.url_screenshot != "",
        order_by: [desc: l.end_date],
        select: %{end_date: l.end_date}

        result = Repo.all(query)

        if result != [] do
          log = result |> List.first
          date_n = Repo.one(from s in Session, where: s.user_id== ^us.id and s.is_active == true,
          select: s.ends)
          if date_n != nil do
            date_nw = Ecto.DateTime.to_erl(date_n) |> Date.from
            date = Ecto.DateTime.to_erl(local) |> Date.from
            if (Date.diff(date_nw, date, :mins) < 7 and Date.diff(date_nw, date, :mins) >= 0) == true do
               imgstatus = 1
            else
               imgstatus = 0
            end
          else
            imgstatus = 0
          end
          date = Ecto.DateTime.to_erl(local) |> Date.from
          date_int = Ecto.DateTime.to_erl(us.inst) |> Date.from
          if (Date.diff(date_int, date, :days) <= 7) == true do
             ins = 1
          else
             ins = 0
          end

          {t, _} = TimesCalc.onlineTime( TimeQ.today(user_id.timezone), [us.id], all_proj)
          {time_h, time_m} = {t.time_h, t.time_m}

          {t7, _} = TimesCalc.onlineTime( TimeQ.last7days(user_id.timezone), [us.id], all_proj)
          {times_h, times_m} = {t7.time_h, t7.time_m}

          fin = %{id: us.id, fullname: us.first_name <> " " <> us.last_name, avatar: us.avatar, time_h: time_h, time_m: time_m, times_h: times_h, times_m: times_m, imgstatus: imgstatus, email: us.email, inserted: ins}
        else
          date = Ecto.DateTime.to_erl(local) |> Date.from
          date_int = Ecto.DateTime.to_erl(us.inst) |> Date.from
          if (Date.diff(date_int, date, :days) <= 7) == true do
             ins = 1
          else
             ins = 0
          end
          fin = %{id: us.id, fullname: us.first_name <> " " <> us.last_name, avatar: us.avatar, time_h: 0, time_m: 0, times_h: 0, times_m: 0, imgstatus: 0, email: us.email, inserted: ins}
        end
      end)

      u_nil = Enum.filter(userss, &(&1 != nil))
      #counts = Enum.map(u_nil, fn(us) ->
       # imgstatus = us.imgstatus
        #  if imgstatus == 1 do
         #     count = 1
          #else
           #   count = 0
          #end
          #count
      #end)
      #counts_ins = Enum.map(u_nil, fn(us) ->
       # inst = us.inserted
        #  if inst == 1 do
         #     count = 1
          #else
          #    count = 0
          #end
          #count
      #end)
      online = Enum.count(Enum.filter(u_nil, &(&1.imgstatus == 1)))
      offline= Enum.count(Enum.filter(u_nil, &(&1.imgstatus == 0)))
      new = Enum.count(Enum.filter(u_nil, &(&1.inserted == 1)))
      total = Enum.count(userss)

    if _params["type"] == "value" do
      users = u_nil
      render conn, :users_all, users: users
    end

    if _params["type"] == "all" do
      users = %{online: online, offline: offline, total: total, new: new, idsession: user_id.id}
      render conn, :users_all, users: users
    end

    render conn, :users_all, users: users
  end

  def get_day_time(u_id, u_org, timezone) do

    {date1, date2} = TimeQ.today(timezone)

    query = from l in Log, join: uo in UserOrganization, on: uo.user_id == ^u_id,
      where: uo.organization_id == ^u_org,
      where: l.user_id == ^u_id,
      where: l.status != "I",
      where: l.end_date >= ^date1,
      where: l.end_date <= ^date2,
      select: sum(l.timer)
    timer_sess = Repo.one(query)
    if !timer_sess do
         {0,0}
    else
        {div(timer_sess,3600), div(rem(timer_sess,3600),60)}
    end
  end

  defp get_7day_time(u_id, u_org, timezone) do

      {date1, date2} = TimeQ.last7days(timezone)

    query = from l in Log, join: uo in UserOrganization, on: uo.user_id == ^u_id,
      where: uo.organization_id == ^u_org,
      where: l.user_id == ^u_id,
      where: l.status != "I",
      where: l.end_date >= ^date1,
      where: l.end_date <= ^date2,
      select: sum(l.timer)
    timer_sess = Repo.one(query)
    if !timer_sess do
         {0,0}
    else
        {div(timer_sess,3600), div(rem(timer_sess,3600),60)}
    end
  end

  def get_timezone(conn, _params) do
    zone = Repo.all(from z in Ttimezone, select: %{id: z.id, name: z.name})
    render conn, :menssage, user: zone
  end

  def profile(conn, %{"id" => id} ) do
    #user_id = get_session(conn, :current_user)
    us = Repo.one(from u in User, where: u.id ==^id)
    timezone = Repo.one(from z in Ttimezone, where: z.id == ^us.timezone_id, select: z.name)
    user = %{name: us.first_name <> " " <> us.last_name, avatar: us.avatar, email: us.email,
    insert: us.inserted_at, username: us.username, timezone: timezone}
    render conn, :menssage, user: user
  end

  def profile_projects(conn, %{"id" => id}) do
    org = get_session(conn, :current_organization)
    project = Repo.all(from p in UserProject, join: pr in Project, on: pr.id == p.project_id,
    where: p.user_id == ^id,
    where: pr.organization_id == ^org.id,
    select: %{id: p.id, name: pr.project_name, start_date: p.inserted_at})
    render conn, :menssage, user: project
  end

  def user_service(conn, _params) do
    user = get_session(conn, :current_user)
    us = Repo.one(from u in User, where: u.id == ^user.id)
    user = %{id: us.id, name: us.username, img: us.avatar}
    render conn, :menssage, user: user
  end

  def org_service(conn, _params) do
    user = get_session(conn, :current_user)
    org = get_session(conn, :current_organization)
    proj = Repo.all(from p in UserProject, join: pr in Project, on: pr.id == p.project_id,
    where: p.user_id == ^user.id,
    where: pr.organization_id == ^org.id,
    select: %{id: p.id, name: pr.project_name})

    user = %{org: org.name, project: proj}
    render conn, :menssage, user: user
  end

end
