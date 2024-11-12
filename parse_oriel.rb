#!/usr/bin/env ruby

require 'fileutils'
require 'httparty'
require 'json'
require 'nokogiri'
require 'open-uri'

# unbuffer stdout + stderr
$stdout.sync = true
$stderr.sync = true

# pretend to be Google crawler
USER_AGENT = 'Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) ' \
             'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/1.2.3.4 Mobile Safari/537.36 ' \
             '(compatible; Googlebot/2.1; +http://www.google.com/bot.html)'
OUTPUT_DIR = './dump'
HOME_URL = 'http://www.orielcolwyn.org'

$articles = Hash.new

def get_url(url)
  Nokogiri::HTML(URI.parse(url).open('User-Agent' => USER_AGENT))
end
                                     
def parse_home_page(home_page)
  article_id = 0
  home_page.css('.post').each do |post|
    article_id += 1
    article = Hash.new
    article['title'] = post.at_css('h2').text
    article['description'] = post.at_css('.description').css('p').text
    post.children.each do |child|
      next unless child.is_a?(Nokogiri::XML::Element)
        if child.name == 'img'
          article['home_page_image'] = child.attr('src')
          article['home_page_image_alt'] = child.attr('alt')
        end
      next unless child.name == 'div'
      child.children.each do |child2|
        next unless child2.is_a?(Nokogiri::XML::Element)
        if child2.name == 'a'
          article['article_url'] = child2.attr('href')
        end
      end
    end
    $articles[article_id] = article

    article_page = get_url(article['article_url'])
    parse_article(article_id, article_page)
  end
end

def parse_article(article_id, page)
  STDERR.puts article_id
  image_counter = 0
  link_counter = 0

  # remove stuff we don't want
  page.at_css('.et-no-big-image').at_css('.meta-info').remove
  page.at_css('.sharedaddy').remove
  # articles 1 - 12 have a link to Welsh version
  if article_id <= 12
    $articles[article_id]['cy_url'] = page.at_css('.wp-block-button').css('a').attr('href').text
    page.at_css('.wp-block-button').remove
  end
  # these articles have a link to a Welsh version in a different style
  if [18,19,20,21,22,24,25,26].include?(article_id)
    $articles[article_id]['cy_url'] = page.at_css('.small-button').attr('href')
    page.at_css('.small-button').remove
  end

  # find links
  $articles[article_id]['links'] = []
  page.at_css('.et-no-big-image').css('a').each do |a|
    # skip if no href
    next unless a.attr('href')
    link_counter += 1
    # insert link placeholder to body
    a.before("<strong>{{LINK #{link_counter}}}</strong>")
    $articles[article_id]['links'] << a.attr('href')
  end

  # find images
  $articles[article_id]['images'] = []
  if article_id < 18
    page.at_css('.et-no-big-image').css('.wp-block-image').css('figure').each do |image|
      # these are the footer images, skip them
      next if image.css('img').attr('src').text.include?('SPF-Footer-Logos')
      image_counter += 1
      # insert image placeholder to body
      image.at_css('img').add_child("<strong>{{IMAGE #{image_counter}}}</strong>\n")
      $articles[article_id]['images'] << image.at_css('img').attr('src')
    end
  else
    # code for 'aligncenter' images
    page.css('.aligncenter').each do |image|
      image_counter += 1
      #pp image_counter
      #pp image
      if image.name == 'img'
        #pp image.attr('src')
        #image.before("<strong>{{IMAGE #{image_counter}}}</strong>")
        $articles[article_id]['images'] << image.attr('src')
      elsif image.name == 'div'
        # stuff dealing with nested in a div
        image.children.each do |child|
          next unless child.name == 'img'
          #pp child.attr('src')
          $articles[article_id]['images'] << child.attr('src')
        end
      end
      image.before("<strong>{{IMAGE #{image_counter}}}</strong>")
    end
  end

  # remove tabs, duplicate newlines and duplicate spaces from body
  article_body = page.at_css('.et-no-big-image').text.gsub(/\t+/, '').gsub(/\n{2,}/, "\n\n").squeeze(' ')
  $articles[article_id]['body'] = article_body
end


# 'main()'

home_page = get_url(HOME_URL)
parse_home_page(home_page)
# print out JSON representation of site
puts JSON.pretty_generate(JSON.parse($articles.to_json))

# go through the articles and write the elements to disk
$articles.each do |article_id, article|
  STDERR.puts article_id
  article_dir = "#{OUTPUT_DIR}/#{article_id.to_s}"
  FileUtils.mkdir_p("#{article_dir}/images")
  File.write("#{article_dir}/meta.txt", "title:#{article['title']}")
  File.write("#{article_dir}/meta.txt", "\ndescription:#{article['description']}", mode: 'a')
  File.write("#{article_dir}/meta.txt", "\nurl:#{article['article_url']}", mode: 'a')
  File.write("#{article_dir}/body.txt", article['body'])
  
  FileUtils.rm_f("#{article_dir}/links.txt")
  link_counter = 0
  article['links'].each do |link|
    link_counter += 1
    File.write("#{article_dir}/links.txt", "#{link_counter}:#{link}\n", mode: 'a')
  end

  if article['cy_url']
    File.write("#{article_dir}/cy_url.txt", article['cy_url'])
  end

  image_suffix = article['title'].tr('^A-Za-z0-9', '-').downcase.squeeze('-')
  FileUtils.rm_rf("#{article_dir}/images")
  FileUtils.mkdir_p("#{article_dir}/images")
  image_counter = 0
  article['images'].each do |image|
    image_counter += 1
    image.gsub!(/^https:/, 'http:')
    img_uri = URI.parse(URI::Parser.new.escape(image))
    file_extension = File.extname(image)
    img_r = HTTParty.get(img_uri)
    File.open("#{article_dir}/images/#{image_suffix}-#{image_counter}#{file_extension}", 'wb') do |f|
      f.write(img_r)
    end
  end
end
